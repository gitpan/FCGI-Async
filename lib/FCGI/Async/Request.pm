#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005-2007 -- leonerd@leonerd.org.uk

package FCGI::Async::Request;

use strict;

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
rather, objects in this class are passed into the C<on_request> callback of
the containing C<FCGI::Async> object.

 use FCGI::Async;
 use IO::Async::Set::IO_Poll;

 my $fcgi = FCGI::Async->new(
    on_request => sub {
       my ( $fcgi, $req ) = @_;

       my $path = $req->param( "PATH_INFO" );
       $req->print_stdout( "Status: 200 OK\r\n" .
                           "Content-type: text/plain\r\n" .
                           "\r\n" .
                           "You requested $path" );
       $req->finish();
    }
 );

 my $set = IO::Async::Set::IO_Poll->new();

 $set->add( $fcgi );

 $set->loop_forever;

=cut

# Internal functions

sub new
{
   my $class = shift;
   my %args = @_;

   my $rec = $args{rec};

   my $content = $rec->{content};
   my ( $role, $flags ) = unpack( "nc", $content );

   my $self = bless {
      conn       => $args{conn},
      fcgi       => $args{fcgi},

      reqid      => $rec->{reqid},
      role       => $role,
      keepconn   => $flags & FCGI_KEEP_CONN,

      state      => STATE_ACTIVE,
      stdin      => "",
      stdindone  => 0,
      params     => {},
      paramsdone => 0,

      used_stderr => 0,
   }, $class;

   return $self;
}

sub writerecord
{
   my $self = shift;
   my ( $rec ) = @_;

   my $content = $rec->{content};
   my $contentlen = length( $content );
   if( $contentlen > MAXRECORDDATA ) {
      warn __PACKAGE__."->writerecord() called with content longer than ".MAXRECORDDATA." bytes - truncating";
      $content = substr( $content, 0, MAXRECORDDATA );
   }

   $rec->{reqid} = $self->{reqid} unless defined $rec->{reqid};

   my $conn = $self->{conn};

   $conn->sendrecord( $rec, $content );

}

sub incomingrecord
{
   my $self = shift;
   my ( $rec ) = @_;

   my $type    = $rec->{type};

   if( $type == FCGI_PARAMS ) {
      $self->incomingrecord_params( $rec );
   }
   elsif( $type == FCGI_STDIN ) {
      $self->incomingrecord_stdin( $rec );
   }
   else {
      warn "$self just received unknown record type";
   }
}

sub _ready_check
{
   my $self = shift;

   if( $self->{stdindone} and $self->{paramsdone} ) {
      $self->{fcgi}->_request_ready( $self );
   }
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

   $self->_ready_check;
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

   $self->_ready_check;
}

=head1 FUNCTIONS

=cut

=head2 $hashref = $req->params

This method returns a reference to a hash containing a copy of the request
parameters that had been sent by the webserver as part of the request.

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

   if( $self->{stdin} =~ s/^(.*[\r\n])// ) {
      return $1;
   }
   elsif( $self->{stdin} =~ s/^(.+)// ) {
      return $1;
   }
   else {
      return undef;
   }
}

=head2 $data = $req->read_stdin( $size )

This method works similarly to the C<read(HANDLE)> function. It returns the
next block of up to $size bytes from the STDIN buffer. If no data is available
any more, then C<undef> is returned instead.

=cut

sub read_stdin
{
   my $self = shift;
   my ( $size ) = @_;

   return undef unless length $self->{stdin};

   # If $size is too big, substr() will cope
   return substr( $self->{stdin}, 0, $size, "" );
}

sub _print_stream
{
   my $self = shift;
   my ( $data, $stream ) = @_;

   while( length $data ) {
      # Send chunks of up to MAXRECORDDATA bytes at once
      my $chunk = substr( $data, 0, MAXRECORDDATA, "" );
      $self->writerecord( { type => $stream, content => $chunk } );
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

   $self->_print_stream( $data, FCGI_STDOUT );
}

=head2 $req->print_stderr( $data )

This method appends the given data to the STDERR stream of the FastCGI
request, sending it to the webserver.

=cut

sub print_stderr
{
   my $self = shift;
   my ( $data ) = @_;

   $self->{used_stderr} = 1;
   $self->_print_stream( $data, FCGI_STDERR );
}

sub end_request
{
   my $self = shift;
   my ( $status, $protstatus ) = @_;

   my $content = pack( "Ncccc", $status, $protstatus, 0, 0, 0 );

   $self->writerecord( { type => FCGI_END_REQUEST, content => $content } );
}

=head2 $req->finish( $exitcode )

When the request has been dealt with, this method should be called to indicate
to the webserver that it is finished. After calling this method, no more data
may be appended to the STDOUT stream. At some point after calling this method,
the request object will be removed from the containing C<FCGI::Async> object,
once all the buffered outbound data has been sent.

If present, C<$exitcode> should indicate the numeric status code to send to
the webserver. If absent, a value of C<0> is presumed.

=cut

sub finish
{
   my $self = shift;
   my ( $exitcode ) = @_;

   # Signal the end of STDOUT
   $self->writerecord( { type => FCGI_STDOUT, content => "" } );

   # Signal the end of STDERR if we used it
   $self->writerecord( { type => FCGI_STDERR, content => "" } ) if $self->{used_stderr};

   $self->end_request( $exitcode || 0, FCGI_REQUEST_COMPLETE );

   my $conn = $self->{conn};
   $conn->_removereq( $self->{reqid} );
}

# Keep perl happy; keep Britain tidy
1;
