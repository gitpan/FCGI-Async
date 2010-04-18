use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'FCGI::Async',
   requires => {
      'Encode'              => 0,
      'IO::Async::Listener' => '0.23',
      'IO::Async::Loop'     => '0.16',
      'IO::Async::Test'     => 0,
      'Net::FastCGI::Constant' => '0.10',
      'Net::FastCGI::Protocol' => '0.10',
   },
   build_requires => {
      'Test::HexString' => 0,
      'Test::More'      => 0,
   },
   license => 'perl',
   create_makefile_pl => 'traditional',
   create_license => 1,
   create_readme  => 1,
  );
  
$build->create_build_script;
