#!/usr/bin/perl -w

use strict;

use Test::More tests => 9;

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
   # Begin
   fcgi_trans( type => 1, id => 1, data => "\0\1\0\0\0\0\0\0" ) .
   # Parameters
   fcgi_trans( type => 4, id => 1, data => "\3\3FOOfoo\5\5SPLOTsplot" ) .
   # End of parameters
   fcgi_trans( type => 4, id => 1, data => "" ) .
   # STDIN
   fcgi_trans( type => 5, id => 1, data => "Hello, FastCGI script\r\n" . 
                                           "Here are several lines of data\r\n" .
                                           "They should appear on STDIN\r\n" ) .
   # End of STDIN
   fcgi_trans( type => 5, id => 1, data => "" )
);

wait_for { defined $request };

ok( $request->isa( 'FCGI::Async::Request' ), '$request isa FCGI::Async::Request' );

is_deeply( $request->params,
           { FOO => 'foo', SPLOT => 'splot' },
           '$request has correct params' );
is( $request->read_stdin_line,
    "Hello, FastCGI script\r\n",
    '$request has correct STDIN line 1' );
is( $request->read_stdin_line,
    "Here are several lines of data\r\n",
    '$request has correct STDIN line 2' );
is( $request->read_stdin_line,
    "They should appear on STDIN\r\n",
    '$request has correct STDIN line 3' );
is( $request->read_stdin_line,
    undef,
    '$request has correct STDIN finish' );

$request->print_stdout( "Hello, world!" );
$request->print_stderr( "Some errors occured\n" );
$request->finish( 5 );

my $expect;

$expect =
   # STDOUT
   fcgi_trans( type => 6, id => 1, data => "Hello, world!" ) .
   # STDERR
   fcgi_trans( type => 7, id => 1, data => "Some errors occured\n" ) .
   # End of STDOUT
   fcgi_trans( type => 6, id => 1, data => "" ) .
   # End of STDERR
   fcgi_trans( type => 7, id => 1, data => "" ) .
   # End request
   fcgi_trans( type => 3, id => 1, data => "\0\0\0\5\0\0\0\0" );

my $buffer;

$buffer = "";

wait_for {
   $C->sysread( $buffer, 8192, length $buffer ) or $! == EAGAIN or die "Cannot sysread - $!";
   return ( length $buffer >= length $expect );
};

is( $buffer, $expect, 'FastCGI end request record' );
