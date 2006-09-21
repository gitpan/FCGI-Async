#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'FCGI::Async' );
}

diag( "Testing FCGI::Async $FCGI::Async::VERSION, Perl $], $^X" );
