#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005,2006 -- leonerd@leonerd.org.uk

package FCGI::Async::Request;

use strict;

use base qw( IO::Async::Buffer );

use FCGI::Async::Constants;
use FCGI::Async::BuildParse;

=head1 NAME

FCGI::Async::Request - Class to represent one active FastCGI request

=cut

# The largest we'll try to send() down the network at any one time
use constant MAXSENDSIZE => 4096;

# The largest amount of data we can fit in a FastCGI record - MUST NOT
# be greater than 2^16-1
use constant MAXRECORDDATA => 65535;

use POSIX qw( EAGAIN );

=head1 SYNOPSIS

This module would not be used directly by a program using C<FCGI::Async>, but
rather, objects in this class would be obtained by the C<waitingreq()> method:

 my $fcgi = FCGI::Async->new();
 while( 1 ) {
    $fcgi->select();
    while( my $req = $fcgi->waitingreq ) {
       my $path = $req->param( "PATH_INFO" );
       $req->print_stdout( "HTTP/1.0 200 OK\r\n" .
                           "Content-type: text/plain\r\n" .
                           "\r\n" .
                           "You requested $path" );
       $req->finish();
    }
 }

=cut

# Internal functions

sub new
{
   my $class = shift;
   my ( $sock, $fcgi ) = @_;

   my $self = $class->SUPER::new( handle => $sock );

   $self->{fcgi}       = $fcgi;
   $self->{state}      = STATE_NEW;
   $self->{stdin}      = "";
   $self->{stdindone}  = 0;
   $self->{params}     = {};
   $self->{paramsdone} = 0;

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
      $fcgi->_removereq( $self );
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

   $self->incomingrecord( $rec );

   return 1;
}

sub on_outgoing_empty
{
   my $self = shift;

   if( $self->{state} == STATE_PENDINGREMOVE ) {
      my $fcgi = $self->{fcgi};
      $fcgi->_removereq( $self );
   }
}

sub writerecord
{
   my $self = shift;
   my ( $rec ) = @_;

   if( $self->{state} == STATE_PENDINGREMOVE ) {
      die "Cannot append further output data to a request in pendingremove state";
   }

   my $content = $rec->{content};
   my $contentlen = length( $content );
   if( $contentlen > MAXRECORDDATA ) {
      warn __PACKAGE__."->writerecord() called with content longer than ".MAXRECORDDATA." bytes - truncating";
      $content = substr( $content, 0, MAXRECORDDATA );
   }

   $rec->{reqid} = $self->{reqid} unless defined $rec->{reqid};

   my $buffer = FCGI::Async::BuildParse::build_record( $rec, $content );

   $self->send( $buffer );
}

sub incomingrecord
{
   my $self = shift;
   my ( $rec ) = @_;

   my $type    = $rec->{type};

   if( $type == FCGI_BEGIN_REQUEST ) {
      $self->incomingrecord_begin( $rec );
   }
   elsif( $type == FCGI_PARAMS ) {
      $self->incomingrecord_params( $rec );
   }
   elsif( $type == FCGI_STDIN ) {
      $self->incomingrecord_stdin( $rec );
   }
   else {
      warn "$self just received unknown record type";
   }
}

sub incomingrecord_begin
{
   my $self = shift;
   my ( $rec ) = @_;

   my $content = $rec->{content};

   $self->{state} = STATE_ACTIVE;
   $self->{reqid} = $rec->{reqid};
   my ( $role, $flags ) = unpack( "nc", $content );
   $self->{role} = $role;
   $self->{keepconn} = $flags & FCGI_KEEP_CONN;
}

sub incomingrecord_params
{
   my $self = shift;
   my ( $rec ) = @_;

   my $content = $rec->{content};
   my $len     = $rec->{len};

   if( $len ) {
      my $paramshash = FCGI::Async::BuildParse::parse_namevalues( $content );
      my $p = $self->{params};
      foreach ( keys %$paramshash ) {
         $p->{$_} = $paramshash->{$_};
      }
   }
   else {
      $self->{paramsdone} = 1;
   }
}

sub incomingrecord_stdin
{
   my $self = shift;
   my ( $rec ) = @_;

   my $content = $rec->{content};
   my $len     = $rec->{len};

   if( $len ) {
      $self->{stdin} .= $content;
   }
   else {
      $self->{stdindone} = 1;
   }
}

=head1 FUNCTIONS

=cut

=head2 %p = $req->params

This method returns a copy of the hash of request parameters that had been
sent by the webserver as part of the request.

=cut

sub params
{
   my $self = shift;

   my %p = %{$self->{params}};

   return \%p;
}

=head2 $p = $req->param( $key )

This method returns the value of a single request parameter, or C<undef> if no
such key exists.

=cut

sub param
{
   my $self = shift;
   my ( $key ) = @_;

   return $self->{params}{$key};
}

=head2 $isready = $req->ready

This method returns a true when the request is ready to be processed; i.e.,
that the complete state has been streamed from the webserver.

=cut

sub ready
{
   my $self = shift;

   return ( $self->{stdindone} and 
            $self->{paramsdone} and 
            $self->{state} != STATE_PENDINGREMOVE );
}

=head2 $line = $req->read_stdin_line

This method works similarly to the C<< <HANDLE> >> operator. If at least one
line of data is available then it is returned, including the linefeed, and
removed from the buffer. If not, then any remaining partial line is returned
and removed from the buffer. If no data is available any more, then C<undef>
is returned instead.

=cut

sub read_stdin_line
{
   my $self = shift;

   if( $self->{stdin} =~ s/^(.*[\r\n])+// ) {
      return $1;
   }
   elsif( $self->{stdin} =~ s/^(.*)// ) {
      return $1;
   }
   else {
      return undef;
   }
}

=head2 $req->print_stdout( $data )

This method appends the given data to the STDOUT stream of the FastCGI
request, sending it to the webserver to be sent to the client.

=cut

sub print_stdout
{
   my $self = shift;
   my ( $data ) = @_;

   while( length $data ) {
      # Send chunks of up to MAXRECORDDATA bytes at once
      my $chunk = substr( $data, 0, MAXRECORDDATA, "" );
      $self->writerecord( { type => FCGI_STDOUT, content => $chunk } );
   }
}

sub end_request
{
   my $self = shift;
   my ( $status, $protstatus ) = @_;

   my $content = pack( "Ncccc", $status, $protstatus, 0, 0, 0 );

   $self->writerecord( { type => FCGI_END_REQUEST, content => $content } );
}

=head2 $req->finish

When the request has been dealt with, this method should be called to indicate
to the webserver that it is finished. After calling this method, no more data
may be appended to the STDOUT stream. At some point after calling this method,
the request object will be removed from the containing C<FCGI::Async> object,
once all the buffered outbound data has been sent.

=cut

sub finish
{
   my $self = shift;

   $self->print_stdout( "" );
   $self->end_request( 0, FCGI_REQUEST_COMPLETE );

   $self->{state} = STATE_PENDINGREMOVE;
}

# Keep perl happy; keep Britain tidy
1;
