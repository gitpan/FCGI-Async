#!/usr/bin/perl -w

use strict;

use FCGI::Async;

use IO::Async::Stream;
use IO::Async::SignalProxy;
use IO::Async::Loop::IO_Poll;

use IPC::Open3;
use POSIX qw( WNOHANG );

my $FORTUNE = "/usr/games/fortune";

my $loop;

sub on_request
{
   my ( $fcgi, $req ) = @_;
   
   # These following variables are important because we're about to form a
   # number of closures over them
   my ( $childin, $childout, $childerr ) = map { IO::Handle->new } ( 0 .. 2 );
   my $kid = open3( $childin, $childout, $childerr, $FORTUNE );

   if( !defined $kid ) {
      $req->print_stdout(
         "Content-type: text/plain\r\n" .
         "\r\n" .
         "Could not run $FORTUNE - $!\r\n"
      );

      $req->finish;
      return;
   }

   # Print CGI header
   $req->print_stdout(
      "Content-type: text/html\r\n" .
      "\r\n" .
      "<html>" . 
      " <head><title>Fortune</title></head>" . 
      " <body><h1>$FORTUNE says:</h1>"
   );

   # We consider the request finished when all the following three conditions
   # are satisfied:
   #  1: child's STDOUT is closed
   #  2: child's STDERR is closed
   #  3: child has died and thrown SIGCHLD to us
   # This closure checks all three conditions, and finishes the request if
   # they all hold. We don't know what order these might be reported to us in
   # so we have to check all three each time one of them becomes true.
   my $finishhandler = sub {
      return if defined $childout;
      return if defined $childerr;
      return if defined $kid;

      $req->finish;
   };

   # Child's STDOUT

   my $childout_notifier = IO::Async::Stream->new(
      read_handle => $childout,

      on_read => sub {
         my ( $notifier, $buffref, $closed ) = @_;

         if( $$buffref =~ s{^(.*?)\n}{} ) {
            $req->print_stdout( "<p>$1</p>" );
            return 1;
         }

         if( $closed ) {
            $fcgi->remove_child( $notifier );

            # Deal with a final partial line the child may have written
            $req->print_stdout( "<p>$$buffref</p>" ) if length $$buffref;

            $req->print_stdout( "</body></html>" );

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
