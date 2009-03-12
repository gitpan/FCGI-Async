use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'FCGI::Async',
   requires => {
                 'IO::Async::Loop' => '0.16',
                 'IO::Async::Test' => 0,
               },
   build_requires => {
                        'Test::HexString' => 0,
                        'Test::More'      => 0,
                     },
   license => 'perl',
   create_makefile_pl => 'traditional',
  );
  
$build->create_build_script;
