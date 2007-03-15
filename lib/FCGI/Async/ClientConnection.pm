#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005-2007 -- leonerd@leonerd.org.uk

package FCGI::Async::ClientConnection;

use strict;

use base qw( IO::Async::Buffer );

use FCGI::Async::Constants;
use FCGI::Async::Request;

sub new
{
   my $class = shift;
   my ( $sock, $fcgi ) = @_;

   my $self = $class->SUPER::new( handle => $sock );

   $self->{fcgi} = $fcgi;

   $self->{reqs} = {}; # {$reqid} = $req

   return $self;
}

# Callback function for IO::Async::Buffer
sub on_incoming_data
{
   my $self = shift;
   my ( $buffref, $handleclosed ) = @_;

   my $blen = length $$buffref;

   if( $handleclosed ) {
      # Abort
      my $fcgi = $self->{fcgi};
      $fcgi->remove_child( $self );
      return;
   }

   # Do we have a record header yet?
   return 0 unless( $blen >= 8 );

   # Excellent - parse it
   my $rec = FCGI::Async::BuildParse::parse_record_header( $$buffref );

   die "Bad record version" unless( $rec->{ver} eq FCGI_VERSION_1 );

   # Do we have enough for a complete record?
   return 0 unless( $blen >= 8 + $rec->{len} + $rec->{plen} );

   substr( $$buffref, 0, 8, "" ); # Header
   $rec->{content} = substr( $$buffref, 0, $rec->{len}, "" );
   substr( $$buffref, 0, $rec->{plen}, "" ); # Padding

   my $type  = $rec->{type};
   my $reqid = $rec->{reqid};

   if( $type == FCGI_BEGIN_REQUEST ) {
      my $req = FCGI::Async::Request->new( 
         conn => $self,
         fcgi => $self->{fcgi},
         rec  => $rec,
      );
      $self->{reqs}->{$reqid} = $req;
      return 1;
   }

   my $req = $self->{reqs}->{$reqid};

   if( !defined $req ) {
      # TODO! Some sort of error condition?
      return 1;
   }

   $req->incomingrecord( $rec );

   return 1;
}

sub sendrecord
{
   my $self = shift;
   my ( $rec, $content ) = @_;

   my $buffer = FCGI::Async::BuildParse::build_record( $rec, $content );

   $self->send( $buffer );
}

sub _removereq
{
   my $self = shift;
   my ( $reqid ) = @_;

   undef $self->{reqs}->{$reqid};
}

# Keep perl happy; keep Britain tidy
1;
