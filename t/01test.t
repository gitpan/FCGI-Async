#!/usr/bin/perl -w

use strict;

use Test::More tests => 1;

use t::lib::TestFCGI;

is( fcgi_trans( type => 1, id => 1, data => "\0\1\0\0\0\0\0\0" ),
    "\1\1\0\1\0\x08\0\0\0\1\0\0\0\0\0\0",
    'Testing fcgi_trans() internal function' );
