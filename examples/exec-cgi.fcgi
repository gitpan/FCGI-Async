#!/usr/bin/perl -w

use strict;

use FCGI::Async;

use IO::Async::Stream;
use IO::Async::SignalProxy;
use IO::Async::Loop::IO_Poll;

use IPC::Open3;
use POSIX qw( WNOHANG );

my $loop;

sub on_request
{
   my ( $fcgi, $req ) = @_;

   my %req_env = %{ $req->params };

   # Determine these however you like; perhaps examine $req
   my $handler = "./sample.cgi";
   my @handler_args = ();
   
   # These following variables are important because we're about to form a
   # number of closures over them
   pipe( my $C_STDIN,  my $childin  ) and
   pipe( my $childout, my $C_STDOUT ) and
   pipe( my $childerr, my $C_STDERR ) or do {
      $req->print_stdout(
         "Content-type: text/plain\r\n" .
         "\r\n" .
         "Could not pipe - $!\r\n"
      );

      $req->finish;
      return;
   };

   my $kid = fork();

   if( !defined $kid ) {
      $req->print_stdout(
         "Content-type: text/plain\r\n" .
         "\r\n" .
         "Could not run $handler - $!\r\n"
      );

      $req->finish;
      return;
   }

   if( $kid == 0 ) {
      # I'm the child

      # Copy the request environment
      %ENV = %req_env;

      # Set up the IN/OUT/ERR filehandles
      open( STDIN,  "<&", $C_STDIN );
      open( STDOUT, ">&", $C_STDOUT );
      open( STDERR, ">&", $C_STDERR );

      # setuid / setgid / chdir / do whatever you like here

      exec( $handler, @handler_args );
      die "Could not exec $handler - $!";
   }

   # We consider the request finished when all the following three conditions
   # are satisfied:
   #  1: child's STDOUT is closed
   #  2: child's STDERR is closed
   #  3: child has died and thrown SIGCHLD to us
   # This closure checks all three conditions, and finishes the request if
   # they all hold. We don't know what order these might be reported to us in
   # so we have to check all three each time one of them becomes true.
   my $finishhandler = sub {
      return if defined $childin;
      return if defined $childout;
      return if defined $childerr;
      return if defined $kid;

      $req->finish;
   };

   # Child's STDIN
   my $childin_notifier = IO::Async::Stream->new(
      handle => $childin,

      on_read => sub { }, # Ignore it

      on_outgoing_empty => sub {
         my ( $notifier ) = @_;

         $fcgi->remove_child( $notifier );

         undef $childin;
         $finishhandler->();
      }
   );

   my $did_stdin = 0;

   while( defined( my $line = $req->read_stdin_line ) ) {
      $childin_notifier->write( $line );

      $did_stdin = 1;
   }

   if( $did_stdin ) {
      $fcgi->add_child( $childin_notifier );
   }
   else {
      undef $childin;
   }

   # Child's STDOUT

   my $childout_notifier = IO::Async::Stream->new(
      read_handle => $childout,

      on_read => sub {
         my ( $notifier, $buffref, $closed ) = @_;

         $req->print_stdout( $$buffref );
         $$buffref = "";

         if( $closed ) {
            $fcgi->remove_child( $notifier );

            # Mark that condition 1 above is true, and check for finishing
            undef $childout;
            $finishhandler->();
         }

         return 0;
      }
   );

   $fcgi->add_child( $childout_notifier );

   # Child's STDERR

   my $childerr_notifier = IO::Async::Stream->new(
      read_handle => $childerr,

      on_read => sub {
         my ( $notifier, $buffref, $closed ) = @_;

         if( $$buffref =~ s{^(.*?)\n}{} ) {
            $req->print_stderr( $1 );
            return 1;
         }

         if( $closed ) {
            $fcgi->remove_child( $notifier );

            # Deal with a final partial line the child may have written
            $req->print_stderr( "$$buffref\n" ) if length $$buffref;

            # Mark that condition 2 above is true, and check for finishing
            undef $childerr;
            $finishhandler->();
         }

         return 0;
      }
   );

   $fcgi->add_child( $childerr_notifier );

   # Child's death

   $loop->watch_child( $kid, sub {
      # Mark that condition 3 above is true, and check for finishing
      undef $kid;
      $finishhandler->();
   } );
}

my $fcgi = FCGI::Async->new(
   on_request => \&on_request,
);

$loop = IO::Async::Loop::IO_Poll->new();

$loop->add( $fcgi );

$loop->enable_childmanager();

$loop->loop_forever();
