#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;

use IO::Async::Loop;
use IO::Async::Test;

use POSIX qw( EAGAIN );

use FCGI::Async;

use t::lib::TestFCGI;

my ( $S, $selfaddr ) = make_server_sock;

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my $fcgi = FCGI::Async->new(
   loop => $loop,

   handle => $S,
   on_request => sub {
      my ( $fcgi, $req ) = @_;

      my $data = $req->param( 'data' );

      $req->print_stdout( "You wrote $data" );
      $req->finish;
   },
);

ok( defined $fcgi, 'defined $fcgi' );
is( ref $fcgi, "FCGI::Async", 'ref $fcgi is FCGI::Async' );

my $C = connect_client_sock( $selfaddr );

# Got it - now pretend to be an FCGI client, such as how a webserver would
# behave.

$C->syswrite(
   # Begin 1 with FCGI_KEEP_CONN
   fcgi_trans( type => 1, id => 1, data => "\0\1\1\0\0\0\0\0" ) .
   # Begin 2 with FCGI_KEEP_CONN
   fcgi_trans( type => 1, id => 2, data => "\0\1\1\0\0\0\0\0" ) .
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

my $expect;

$expect =
   # STDOUT
   fcgi_trans( type => 6, id => 1, data => "You wrote Value" ) .
   # End of STDOUT
   fcgi_trans( type => 6, id => 1, data => "" ) .
   # End request
   fcgi_trans( type => 3, id => 1, data => "\0\0\0\0\0\0\0\0" );

my $buffer;

$buffer = "";

wait_for {
   $C->sysread( $buffer, 8192, length $buffer ) or $! == EAGAIN or die "Cannot sysread - $!";
   return ( length $buffer >= length $expect );
};

is( $buffer, $expect, 'FastCGI end request record' );

$C->syswrite(
   # No STDIN 2
   fcgi_trans( type => 5, id => 2, data => "" )
);

$expect =
   # STDOUT
   fcgi_trans( type => 6, id => 2, data => "You wrote Other value" ) .
   # End of STDOUT
   fcgi_trans( type => 6, id => 2, data => "" ) .
   # End request
   fcgi_trans( type => 3, id => 2, data => "\0\0\0\0\0\0\0\0" );

$buffer = "";

wait_for {
   $C->sysread( $buffer, 8192, length $buffer ) or $! == EAGAIN or die "Cannot sysread - $!";
   return ( length $buffer >= length $expect );
};

is( $buffer, $expect, 'FastCGI end request record' );
