#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005-2010 -- leonerd@leonerd.org.uk

package FCGI::Async::ClientConnection;

use strict;
use warnings;

use IO::Async::Stream 0.11;
use base qw( IO::Async::Stream );

use FCGI::Async::Constants;
use FCGI::Async::Request;

sub new
{
   my $class = shift;
   my ( $sock, $fcgi ) = @_;

   my $self = $class->SUPER::new(
      handle => $sock,
      on_closed => sub {
         my ( $self ) = @_;
         $_->_abort for values %{ $self->{reqs} };
      },
   );

   $self->{fcgi} = $fcgi;

   $self->{reqs} = {}; # {$reqid} = $req

   return $self;
}

# Callback function for IO::Async::Stream
sub on_read
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

   if( $reqid == 0 ) {
      # Management records
      if( $type == FCGI_GET_VALUES ) {
         $self->_get_values( $rec );
      }
      else {
         $self->writerecord( { type => FCGI_UNKNOWN_TYPE, reqid => 0 }, pack( "c x7", $type ) );
      }

      return 1;
   }

   if( $type == FCGI_BEGIN_REQUEST ) {
      ( my $role, $rec->{flags} ) = unpack( "nc", $rec->{content} );

      if( $role == FCGI_RESPONDER ) {
         my $req = FCGI::Async::Request->new( 
            conn => $self,
            fcgi => $self->{fcgi},
            rec  => $rec,
         );
         $self->{reqs}->{$reqid} = $req;
      }
      else {
         $self->writerecord( { type => FCGI_END_REQUEST, reqid => $rec->{reqid} }, pack( "N c x3", 0, FCGI_UNKNOWN_ROLE ) );
      }

      return 1;
   }

   # FastCGI spec says we're supposed to ignore any record apart from
   # FCGI_BEGIN_REQUEST on unrecognised request IDs
   my $req = $self->{reqs}->{$reqid} or return 1;

   $req->incomingrecord( $rec );

   return 1;
}

sub on_write_ready
{
   my $self = shift;

   foreach my $req ( values %{ $self->{reqs} } ) {
      $req->_flush_streams;
   }

   $self->SUPER::on_write_ready( @_ );
}

sub on_outgoing_empty
{
   my $self = shift;

   my $want_writeready = 0;

   foreach my $req ( values %{ $self->{reqs} } ) {
      $want_writeready = 1 if $req->_want_writeready;
   }

   $self->want_writeready( $want_writeready );
}

sub writerecord
{
   my $self = shift;
   my ( $rec, $content ) = @_;

   my $buffer = FCGI::Async::BuildParse::build_record( $rec, $content );

   $self->write( $buffer );
}

sub _removereq
{
   my $self = shift;
   my ( $reqid ) = @_;

   delete $self->{reqs}->{$reqid};
}

sub _get_values
{
   my $self = shift;
   my ( $rec ) = @_;

   my $content = $rec->{content};

   my $ret = "";

   while( length $content ) {
      my ( $name ) = FCGI::Async::BuildParse::parse_namevalue( $content );

      my $value = $self->_get_value( $name );
      if( defined $value ) {
         $ret .= FCGI::Async::BuildParse::build_namevalue( $name, $value );
      }
   }

   if( length $ret ) {
      $self->writerecord(
         {
            type  => FCGI_GET_VALUES_RESULT,
            reqid => 0,
         },
         $ret
      );
   }
}

# This is a method so subclasses could hook extra values if they want
sub _get_value
{
   my $self = shift;
   my ( $name ) = @_;

   return 1 if $name eq "FCGI_MPXS_CONNS";

   return $FCGI::Async::MAX_CONNS if $name eq "FCGI_MAX_CONNS";
   return $FCGI::Async::MAX_REQS  if $name eq "FCGI_MAX_REQS";

   return undef;
}

# Keep perl happy; keep Britain tidy
1;
