#!/usr/bin/perl -w

use strict;

use Test::More no_plan => 1;

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

my $set = IO::Async::Set::IO_Poll->new();

# Excellent - now we can start the tests

my $fcgi = FCGI::Async->new(
   'socket' => $S,
   set      => $set,
);

ok( defined $fcgi, 'defined $fcgi' );
is( ref $fcgi, "FCGI::Async", 'ref $fcgi is FCGI::Async' );

# Now attempt to connect a new client to it
my $C = IO::Socket::INET->new(
   Type     => SOCK_STREAM,
);
defined $C or die "Unable to create client socket - $!";
$C->connect( $selfaddr ) or die "Unable to connect socket - $!";

$set->loop_once( 0 );

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

# Begin a transaction
$C->syswrite( fcgi_trans( type => 1, id => 1, data => "\0\1\0\0\0\0\0\0" ) );
$set->loop_once( 0 );

# No parameters
$C->syswrite( fcgi_trans( type => 4, id => 1, data => "" ) );
$set->loop_once( 0 );

# No STDIN
$C->syswrite( fcgi_trans( type => 5, id => 1, data => "" ) );
$set->loop_once( 0 );

my $req = $fcgi->waitingreq;

ok( defined $req, 'defined $req' );

is_deeply( $req->params, {}, '$req has empty params hash' );
is( $req->read_stdin_line, "", '$req has empty STDIN' );

$req->finish;
$set->loop_once( 0 );

my $buffer;
sysread( $C, $buffer, 8192 );

is( $buffer,
    fcgi_trans( type => 3, id => 1, data => "\0\0\0\0\0\0\0\0" ),
    'FastCGI end request record' );
