#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005-2010 -- leonerd@leonerd.org.uk

package FCGI::Async::ClientConnection;

use strict;
use warnings;

use base qw( FCGI::Async::Stream );

use Net::FastCGI::Constant qw( FCGI_VERSION_1 :type :role :protocol_status );
use Net::FastCGI::Protocol qw(
   build_params parse_params
   parse_begin_request_body
   build_end_request_body
);

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

sub on_mgmt_record
{
   my $self = shift;
   my ( $type, $rec ) = @_;

   return $self->_get_values( $rec ) if $type == FCGI_GET_VALUES;

   return $self->SUPER::on_mgmt_record( $type, $rec );
}

sub on_record
{
   my $self = shift;
   my ( $reqid, $rec ) = @_;

   my $type = $rec->{type};

   if( $type == FCGI_BEGIN_REQUEST ) {
      ( my $role, $rec->{flags} ) = parse_begin_request_body( $rec->{content} );

      if( $role == FCGI_RESPONDER ) {
         my $req = FCGI::Async::Request->new( 
            conn => $self,
            fcgi => $self->{fcgi},
            rec  => $rec,
         );
         $self->{reqs}->{$reqid} = $req;
      }
      else {
         $self->write_record( { type => FCGI_END_REQUEST, reqid => $rec->{reqid} }, 
            build_end_request_body( 0, FCGI_UNKNOWN_ROLE )
         );
      }

      return;
   }

   # FastCGI spec says we're supposed to ignore any record apart from
   # FCGI_BEGIN_REQUEST on unrecognised request IDs
   my $req = $self->{reqs}->{$reqid} or return;

   $req->incomingrecord( $rec );
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

   foreach my $name ( keys %{ parse_params( $content ) } ) {
      my $value = $self->_get_value( $name );
      if( defined $value ) {
         $ret .= build_params( { $name => $value } );
      }
   }

   if( length $ret ) {
      $self->write_record(
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
