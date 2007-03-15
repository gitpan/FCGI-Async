#!/usr/bin/perl -w

use strict;

use Test::More tests => 16;

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

my $on_request;

my $fcgi = FCGI::Async->new(
   'socket' => $S,
   on_request => sub { $on_request = $_[1] },
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

$C->syswrite(
   # Begin
   fcgi_trans( type => 1, id => 1, data => "\0\1\0\0\0\0\0\0" ) .
   # Parameters
   fcgi_trans( type => 4, id => 1, data => "\4\5NAMEfirst" ) .
   # End of parameters
   fcgi_trans( type => 4, id => 1, data => "" ) .
   # No STDIN
   fcgi_trans( type => 5, id => 1, data => "" )
);
$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after request' );

my $req = $on_request;

ok( defined $req, 'defined $req' );

is_deeply( $req->params,
           { NAME => 'first' },
           '$req params' );
is( $req->read_stdin_line,
    undef,
    '$req has empty STDIN' );

$req->print_stdout( "one" );
$req->finish;

$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after ->finish()' );

my $buffer;
sysread( $C, $buffer, 8192 );

is( $buffer,
    # STDOUT
    fcgi_trans( type => 6, id => 1, data => "one" ) .
    # End of STDOUT
    fcgi_trans( type => 6, id => 1, data => "" ) .
    # End request
    fcgi_trans( type => 3, id => 1, data => "\0\0\0\0\0\0\0\0" ),
    'FastCGI end request record' );

# Now send a second one
$C->syswrite(
   # Begin
   fcgi_trans( type => 1, id => 1, data => "\0\1\0\0\0\0\0\0" ) .
   # Parameters
   fcgi_trans( type => 4, id => 1, data => "\4\6NAMEsecond" ) .
   # End of parameters
   fcgi_trans( type => 4, id => 1, data => "" ) .
   # No STDIN
   fcgi_trans( type => 5, id => 1, data => "" )
);
$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after request' );

$req = $on_request;

ok( defined $req, 'defined $req' );

is_deeply( $req->params,
           { NAME => 'second' },
           '$req params' );
is( $req->read_stdin_line,
    undef,
    '$req has empty STDIN' );

$req->print_stdout( "two" );
$req->finish;

$ready = $set->loop_once( 0.1 );
is( $ready, 1, '$ready after ->finish()' );

sysread( $C, $buffer, 8192 );

is( $buffer,
    # STDOUT
    fcgi_trans( type => 6, id => 1, data => "two" ) .
    # End of STDOUT
    fcgi_trans( type => 6, id => 1, data => "" ) .
    # End request
    fcgi_trans( type => 3, id => 1, data => "\0\0\0\0\0\0\0\0" ),
    'FastCGI end request record' );
