package FCGI::Async::Constants;

use strict;

# A large number of constants
my %constants = (
   FCGI_VERSION_1         => 1,

   # Values for rectype
   FCGI_BEGIN_REQUEST     => 1,
   FCGI_ABORT_REQUEST     => 2,
   FCGI_END_REQUEST       => 3,
   FCGI_PARAMS            => 4,
   FCGI_STDIN             => 5,
   FCGI_STDOUT            => 6,
   FCGI_STDERR            => 7,
   FCGI_DATA              => 8,
   FCGI_GET_VALUES        => 9,
   FCGI_GET_VALUES_RESULT => 10,
   FCGI_UNKNOWN_TYPE      => 11,

   # Roles in BEGIN_REQUEST
   FCGI_RESPONDER         => 1,
   FCGI_AUTHORIZER        => 2,
   FCGI_FILTER            => 3,

   # Flags in BEGIN_REQUEST
   FCGI_KEEP_CONN         => 1,

   # Protocol Status for END_REQUEST
   FCGI_REQUEST_COMPLETE  => 0,
   FCGI_CANT_MPX_CONN     => 1,
   FCGI_OVERLOADED        => 2,
   FCGI_UNKNOWN_ROLE      => 3,


   # Some internal-use constants, not defined by the FCGI standard
   STATE_NEW           => 1,
   STATE_ACTIVE        => 2,
   STATE_PENDINGREMOVE => 3,
);

require constant;
foreach my $name ( keys %constants ) {
   my $value = $constants{$name};
   import constant $name => $value;
}

our @ISA = qw( Exporter );
our @EXPORT = keys %constants;

require Exporter;
import Exporter;

# Keep perl happy; keep Britain tidy
1;
