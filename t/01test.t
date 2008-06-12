#!/usr/bin/perl -w

use strict;

use Test::More tests => 1;

use t::lib::TestFCGI;

is( fcgi_trans( type => 1, id => 1, data => "ABCDEFGH" ),
    "\1\1\0\1\0\x08\0\0ABCDEFGH",
    'Testing fcgi_trans() internal function' );
