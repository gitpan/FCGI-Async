use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'FCGI::Async',
   dist_author => 'Paul Evans <leonerd@leonerd.org.uk>',
   dist_version_from => 'lib/FCGI/Async.pm',
   requires => {
                 'IO::Async::Notifier' => '0.03',
                 'IO::Async::Stream'   => '0.11',
                 'IO::Async::Loop::IO_Poll' => '0.11',
               },
   build_requires => {
                        'Test::More' => 0,
                     },
   license => 'perl',
   create_makefile_pl => 'traditional',
  );
  
$build->create_build_script;
