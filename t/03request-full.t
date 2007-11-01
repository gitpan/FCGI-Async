#!/usr/bin/perl -w

use strict;

use Test::More tests => 12;

use IO::Async::Set::IO_Poll;

use FCGI::Async;

use t::lib::TestFCGI;

my $on_request;

my ( $S, $selfaddr ) = make_server_sock;

my $fcgi = FCGI::Async->new(
   'socket' => $S,
   on_request => sub { $on_request = $_[1] },
);

my $set = IO::Async::Set::IO_Poll->new();
$set->add( $fcgi );

ok( defined $fcgi, 'defined $fcgi' );
is( ref $fcgi, "FCGI::Async", 'ref $fcgi is FCGI::Async' );

my $C = connect_client_sock( $selfaddr );

my $ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after connect' );

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
$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after request' );

my $req = $on_request;

ok( defined $req, 'defined $req' );

is_deeply( $req->params,
           { FOO => 'foo', SPLOT => 'splot' },
           '$req has correct params' );
is( $req->read_stdin_line,
    "Hello, FastCGI script\r\n",
    '$req has correct STDIN line 1' );
is( $req->read_stdin_line,
    "Here are several lines of data\r\n",
    '$req has correct STDIN line 2' );
is( $req->read_stdin_line,
    "They should appear on STDIN\r\n",
    '$req has correct STDIN line 3' );
is( $req->read_stdin_line,
    undef,
    '$req has correct STDIN finish' );

$req->print_stdout( "Hello, world!" );
$req->print_stderr( "Some errors occured\n" );
$req->finish( 5 );

$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after ->finish()' );

my $buffer;
sysread( $C, $buffer, 8192 );

is( $buffer,
    # STDOUT
    fcgi_trans( type => 6, id => 1, data => "Hello, world!" ) .
    # STDERR
    fcgi_trans( type => 7, id => 1, data => "Some errors occured\n" ) .
    # End of STDOUT
    fcgi_trans( type => 6, id => 1, data => "" ) .
    # End of STDERR
    fcgi_trans( type => 7, id => 1, data => "" ) .
    # End request
    fcgi_trans( type => 3, id => 1, data => "\0\0\0\5\0\0\0\0" ),
    'FastCGI end request record' );
