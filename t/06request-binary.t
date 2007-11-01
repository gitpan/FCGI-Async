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
   # No parameters
   fcgi_trans( type => 4, id => 1, data => "" ) .
   # STDIN
   fcgi_trans( type => 5, id => 1, data => "123456789" ) .
   # End of STDIN
   fcgi_trans( type => 5, id => 1, data => "" )
);
$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after request' );

my $req = $on_request;

ok( defined $req, 'defined $req' );

is_deeply( $req->params,
           {},
           '$req has empty params hash' );
is( $req->read_stdin( 4 ),
    "1234",
    '$req first four STDIN bytes' );
is( $req->read_stdin( 4 ),
    "5678",
    '$req next four STDIN bytes' );
is( $req->read_stdin( 4 ),
    "9",
    '$req last STDIN bytes' );
is( $req->read_stdin( 4 ),
    undef,
    '$req end of STDIN' );

$req->finish;

$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after ->finish()' );

my $buffer;
sysread( $C, $buffer, 8192 );

is( $buffer,
    # End of STDOUT
    fcgi_trans( type => 6, id => 1, data => "" ) .
    # End request
    fcgi_trans( type => 3, id => 1, data => "\0\0\0\0\0\0\0\0" ),
    'FastCGI end request record' );
