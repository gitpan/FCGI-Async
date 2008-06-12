#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005-2008 -- leonerd@leonerd.org.uk

package FCGI::Async::Request;

use strict;

use FCGI::Async::Constants;
use FCGI::Async::BuildParse;

=head1 NAME

FCGI::Async::Request - Class to represent one active FastCGI request

=cut

# The largest amount of data we can fit in a FastCGI record - MUST NOT
# be greater than 2^16-1
use constant MAXRECORDDATA => 65535;

use POSIX qw( EAGAIN );

=head1 SYNOPSIS

This module would not be used directly by a program using C<FCGI::Async>, but
rather, objects in this class are passed into the C<on_request> callback of
the containing C<FCGI::Async> object.

 use FCGI::Async;
 use IO::Async::Loop::IO_Poll;

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

 my $loop = IO::Async::Loop::IO_Poll->new();

 $loop->add( $fcgi );

 $loop->loop_forever;

To serve contents of files on disk, it may be more efficient to use
C<stream_stdout_then_finish>:

    on_request => sub {
       my ( $fcgi, $req ) = @_;

       open( my $file, "<", "/path/to/file" );
       $req->print_stdout( "Status: 200 OK\r\n" .
                           "Content-type: application/octet-stream\r\n" .
                           "\r\n" );

       $req->stream_stdout_then_finish(
          sub { read( $file, my $buffer, 8192 ) or return undef; return $buffer },
          0
       );
    }

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

      stdout     => "",
      stderr     => "",

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

   $conn->writerecord( $rec, $content );

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
any more, then C<undef> is returned instead. If $size is not defined, then it
will return all the available data.

=cut

sub read_stdin
{
   my $self = shift;
   my ( $size ) = @_;

   return undef unless length $self->{stdin};

   $size = length $self->{stdin} unless defined $size;

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

sub _flush_streams
{
   my $self = shift;

   if( length $self->{stdout} ) {
      $self->_print_stream( $self->{stdout}, FCGI_STDOUT );
      $self->{stdout} = "";
   }
   elsif( my $cb = $self->{stdout_cb} ) {
      $cb->();
   }

   if( length $self->{stderr} ) {
      $self->_print_stream( $self->{stderr}, FCGI_STDERR );
      $self->{stderr} = "";
   }
}

sub _want_writeready
{
   my $self = shift;
   return defined $self->{stdout_cb};
}

=head2 $req->print_stdout( $data )

This method appends the given data to the STDOUT stream of the FastCGI
request, sending it to the webserver to be sent to the client.

=cut

sub print_stdout
{
   my $self = shift;
   my ( $data ) = @_;

   $self->{stdout} .= $data;

   my $conn = $self->{conn};
   $conn->want_writeready( 1 );
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
   $self->{stderr} .= $data;

   my $conn = $self->{conn};
   $conn->want_writeready( 1 );
}

=head2 $req->stream_stdout_then_finish( $readfn, $exitcode )

This method installs a callback for streaming data to the STDOUT stream.
Whenever the output stream is otherwise-idle, the function will be called to
generate some more data to output. When this function returns C<undef> it
indicates the end of the stream, and the request will be finished with the
given exit code.

If this method is used, then care should be taken to ensure that the number of
bytes written to the server matches the number that was claimed in the
C<Content-Length>, if such was provided. This logic should be performed by the
containing application; C<FCGI::Async> will not track it.

=cut

sub stream_stdout_then_finish
{
   my $self = shift;
   my ( $readfn, $exitcode ) = @_;

   $self->{stdout_cb} = sub {
      my $data = $readfn->();

      if( defined $data ) {
         $self->print_stdout( $data );
      }
      else {
         delete $self->{stdout_cb};
         $self->finish( $exitcode );
      }
   };

   my $conn = $self->{conn};
   $conn->want_writeready( 1 );
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

   $self->_flush_streams;

   # Signal the end of STDOUT
   $self->writerecord( { type => FCGI_STDOUT, content => "" } );

   # Signal the end of STDERR if we used it
   $self->writerecord( { type => FCGI_STDERR, content => "" } ) if $self->{used_stderr};

   $self->end_request( $exitcode || 0, FCGI_REQUEST_COMPLETE );

   my $conn = $self->{conn};

   if( $self->{keepconn} ) {
      $conn->_removereq( $self->{reqid} );
   }
   else {
      $conn->close;
   }
}

# Keep perl happy; keep Britain tidy
1;
