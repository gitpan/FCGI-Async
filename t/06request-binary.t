#!/usr/bin/perl -w

use strict;

use Test::More tests => 11;

use IO::Async::Loop::IO_Poll;
use IO::Async::Test;

use POSIX qw( EAGAIN );

use FCGI::Async;

use t::lib::TestFCGI;

my $request;

my ( $S, $selfaddr ) = make_server_sock;

my $loop = IO::Async::Loop::IO_Poll->new();
testing_loop( $loop );

my $fcgi = FCGI::Async->new(
   loop => $loop,

   handle => $S,
   on_request => sub { $request = $_[1] },
);

ok( defined $fcgi, 'defined $fcgi' );
is( ref $fcgi, "FCGI::Async", 'ref $fcgi is FCGI::Async' );

my $C = connect_client_sock( $selfaddr );

# Got it - now pretend to be an FCGI client, such as how a webserver would
# behave.

$C->syswrite(
   # Begin with FCGI_KEEP_CONN
   fcgi_trans( type => 1, id => 1, data => "\0\1\1\0\0\0\0\0" ) .
   # No parameters
   fcgi_trans( type => 4, id => 1, data => "" ) .
   # STDIN
   fcgi_trans( type => 5, id => 1, data => "123456789" ) .
   # End of STDIN
   fcgi_trans( type => 5, id => 1, data => "" )
);

wait_for { defined $request };

ok( $request->isa( 'FCGI::Async::Request' ), '$request isa FCGI::Async::Request' );

is_deeply( $request->params,
           {},
           '$request has empty params hash' );
is( $request->read_stdin( 4 ),
    "1234",
    '$request first four STDIN bytes' );
is( $request->read_stdin( 4 ),
    "5678",
    '$request next four STDIN bytes' );
is( $request->read_stdin( 4 ),
    "9",
    '$request last STDIN bytes' );
is( $request->read_stdin( 4 ),
    undef,
    '$request end of STDIN' );

$request->finish;

my $expect;

$expect =
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

# Now send a second one
$C->syswrite(
   # Begin with FCGI_KEEP_CONN
   fcgi_trans( type => 1, id => 1, data => "\0\1\1\0\0\0\0\0" ) .
   # No parameters
   fcgi_trans( type => 4, id => 1, data => "" ) .
   # STDIN
   fcgi_trans( type => 5, id => 1, data => "ABCDEFGH" ) .
   # End of STDIN
   fcgi_trans( type => 5, id => 1, data => "" )
);

undef $request;
wait_for { defined $request };

is( $request->read_stdin( undef ),
    "ABCDEFGH",
    '$request entire STDIN' );

$request->finish;

$expect =
   # End of STDOUT
   fcgi_trans( type => 6, id => 1, data => "" ) .
   # End request
   fcgi_trans( type => 3, id => 1, data => "\0\0\0\0\0\0\0\0" );

$buffer = "";

wait_for {
   $C->sysread( $buffer, 8192, length $buffer ) or $! == EAGAIN or die "Cannot sysread - $!";
   return ( length $buffer >= length $expect );
};

is( $buffer, $expect, 'FastCGI end request record' );
