#!/usr/bin/perl -w

use strict;

use Test::More tests => 9;

use IO::Async::Loop::IO_Poll;

use FCGI::Async;

use t::lib::TestFCGI;

my ( $S, $selfaddr ) = make_server_sock;

my $fcgi = FCGI::Async->new(
   'socket' => $S,
   on_request => sub {
      my ( $fcgi, $req ) = @_;

      my $data = $req->param( 'data' );

      $req->print_stdout( "You wrote $data" );
      $req->finish;
   },
);

my $loop = IO::Async::Loop::IO_Poll->new();
$loop->add( $fcgi );

ok( defined $fcgi, 'defined $fcgi' );
is( ref $fcgi, "FCGI::Async", 'ref $fcgi is FCGI::Async' );

my $C = connect_client_sock( $selfaddr );

my $ready = $loop->loop_once( 0.1 );
is( $ready, 1, '$ready after connect' );

# Got it - now pretend to be an FCGI client, such as how a webserver would
# behave.

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
$ready = $loop->loop_once( 0.1 );
is( $ready, 1, '$ready after request' );

$ready = $loop->loop_once( 0.1 );
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

$ready = $loop->loop_once( 0.1 );
is( $ready, 1, '$ready after request' );

$ready = $loop->loop_once( 0.1 );
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
