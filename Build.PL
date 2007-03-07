use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'FCGI::Async',
   dist_author => 'Paul Evans <leonerd@leonerd.org.uk>',
   dist_version_from => 'lib/FCGI/Async.pm',
   requires => {
                 'IO::Async::Notifier' => '0.02',
                 'IO::Async::Buffer'   => '0.02',
               },
   license => 'perl',
  );
  
$build->create_build_script;
