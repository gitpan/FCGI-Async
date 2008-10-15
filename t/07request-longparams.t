#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;

use IO::Async::Loop;
use IO::Async::Test;

use POSIX qw( EAGAIN );

use FCGI::Async;

use t::lib::TestFCGI;

my $request;

my ( $S, $selfaddr ) = make_server_sock;

my $loop = IO::Async::Loop->new();
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

my $paramvalue = "A" x 240; # Important that 240 is bigger than 127

$C->syswrite(
   # Begin
   fcgi_trans( type => 1, id => 1, data => "\0\1\0\0\0\0\0\0" ) .
   # Parameters
   fcgi_trans( type => 4, id => 1, data => "\4\x80\0\0\xf0LONG$paramvalue" ) .
   # End of parameters
   fcgi_trans( type => 4, id => 1, data => "" ) .
   # No STDIN
   fcgi_trans( type => 5, id => 1, data => "" )
);

wait_for { defined $request };

isa_ok( $request, 'FCGI::Async::Request', '$request isa FCGI::Async::Request' );

is_deeply( $request->params,
           { LONG => $paramvalue },
           '$request has correct params' );
is( $request->read_stdin_line,
    undef,
    '$request has empty STDIN' );

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
