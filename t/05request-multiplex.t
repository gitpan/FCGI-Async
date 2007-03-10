#!/usr/bin/perl -w

use strict;

use Test::More tests => 10;

use IO::Socket::INET;
use IO::Async::Set::IO_Poll;

use FCGI::Async;

my $S = IO::Socket::INET->new(
   Type      => SOCK_STREAM,
   Listen    => 10,
   ReuseAddr => 1,
   Blocking  => 0,
);

defined $S or die "Unable to create socket - $!";

my $selfaddr = $S->sockname;
defined $selfaddr or die "Unable to get sockname - $!";

# Excellent - now we can start the tests

my $fcgi = FCGI::Async->new(
   'socket' => $S,
   on_request => sub {
      my ( $fcgi, $req ) = @_;

      my $data = $req->param( 'data' );

      $req->print_stdout( "You wrote $data" );
      $req->finish;
   },
);

my $set = IO::Async::Set::IO_Poll->new();
$set->add( $fcgi );

ok( defined $fcgi, 'defined $fcgi' );
is( ref $fcgi, "FCGI::Async", 'ref $fcgi is FCGI::Async' );

# Now attempt to connect a new client to it
my $C = IO::Socket::INET->new(
   Type     => SOCK_STREAM,
);
defined $C or die "Unable to create client socket - $!";
$C->connect( $selfaddr ) or die "Unable to connect socket - $!";

my $ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after connect' );

# Got it - now pretend to be an FCGI client, such as how a webserver would
# behave. This test code gets scary to write without effectively writing our
# own FastCGI client implementation. Without doing that, the best thing we can
# do is provide a little helper function to build FastCGI transaction records.
# We'll test that too.

sub fcgi_trans
{
   my %args = @_;

   $args{version} ||= 1;

   my $data = $args{data};
   my $len = length $data;

   #             version type         id         length padlen reserved
   return pack( "C       C            n          n      C      C",
                1,       $args{type}, $args{id}, $len,  0,     0 )
          .
          $data;
}

is( fcgi_trans( type => 1, id => 1, data => "\0\1\0\0\0\0\0\0" ),
    "\1\1\0\1\0\x08\0\0\0\1\0\0\0\0\0\0",
    'Testing fcgi_trans() internal function' );

# We'll start both requests but not quite finish the second one, so we can
# depend on the reply order for testing

$C->syswrite(
   # Begin 1
   fcgi_trans( type => 1, id => 1, data => "\0\1\0\0\0\0\0\0" ) .
   # Begin 2
   fcgi_trans( type => 1, id => 2, data => "\0\1\0\0\0\0\0\0" ) .
   # Parameters 1
   fcgi_trans( type => 4, id => 1, data => "\4\5dataValue" ) .
   # End of parameters 1
   fcgi_trans( type => 4, id => 1, data => "" ) .
   # Parameters 2
   fcgi_trans( type => 4, id => 2, data => "\4\x0bdataOther value" ) .
   # End of parameters 2
   fcgi_trans( type => 4, id => 2, data => "" ) .
   # No STDIN 1
   fcgi_trans( type => 5, id => 1, data => "" )
);
$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after request' );

$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after ->finish()' );

my $buffer;
sysread( $C, $buffer, 8192 );

is( $buffer,
    # STDOUT
    fcgi_trans( type => 6, id => 1, data => "You wrote Value" ) .
    # End of STDOUT
    fcgi_trans( type => 6, id => 1, data => "" ) .
    # End request
    fcgi_trans( type => 3, id => 1, data => "\0\0\0\0\0\0\0\0" ),
    'FastCGI end request record' );

$C->syswrite(
   # No STDIN 2
   fcgi_trans( type => 5, id => 2, data => "" )
);

$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after request' );

$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after ->finish()' );

sysread( $C, $buffer, 8192 );

is( $buffer,
    # STDOUT
    fcgi_trans( type => 6, id => 2, data => "You wrote Other value" ) .
    # End of STDOUT
    fcgi_trans( type => 6, id => 2, data => "" ) .
    # End request
    fcgi_trans( type => 3, id => 2, data => "\0\0\0\0\0\0\0\0" ),
    'FastCGI end request record' );
