#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005-2010 -- leonerd@leonerd.org.uk

package FCGI::Async;

use strict;
use warnings;

use Carp;

use base qw( IO::Async::Listener );

use FCGI::Async::ClientConnection;
use FCGI::Async::Constants;

use IO::Socket::INET;

our $VERSION = '0.19';

# The FCGI_GET_VALUES request might ask for our maximally supported number of
# concurrent connections or requests. We don't really have an inbuilt maximum,
# so just respond these large numbers
our $MAX_CONNS = 1024;
our $MAX_REQS  = 1024;

=head1 NAME

C<FCGI::Async> - respond asynchronously to FastCGI requests

=head1 SYNOPSIS

B<NOTE>: The constructor API of this module has changed since version 0.13!

 use FCGI::Async;
 use IO::Async::Loop;

 my $loop = IO::Async::Loop->new();

 my $fcgi = FCGI::Async->new(
    loop => $loop,
    service => 1234,

    on_request => sub {
       my ( $fcgi, $req ) = @_;

       # Handle the request here
    }
 );

 $loop->loop_forever;

Or

 my $fcgi = FCGI::Async->new(
    on_request => ...
 );

 my $loop = ...

 $loop->add( $fcgi );

 $fcgi->listen( service => 1234 );

=head1 DESCRIPTION

This module allows a program to respond asynchronously to FastCGI requests,
as part of a program based on L<IO::Async>. An object in this class represents
a single FastCGI responder that the webserver is configured to communicate
with. It can handle multiple outstanding requests at a time, responding to
each as data is provided by the program. Individual outstanding requests that
have been started but not yet finished, are represented by instances of
L<FCGI::Async::Request>.

=cut
    
=head1 CONSTRUCTOR

=cut

=head2 $fcgi = FCGI::Async->new( %args )

This function returns a new instance of a C<FCGI::Async> object.

If either a C<handle> or C<service> argument are passed to the constructor,
then the newly-created object is added to the given C<IO::Async::Loop>, then
the C<listen> method is invoked, passing the entire C<%args> hash to it. For
more detail, see the C<listen> method below.

If either of the above arguments are given, then a C<IO::Async::Loop> must
also be provided:

=over 4

=item loop => IO::Async::Loop

A reference to the C<IO::Async::Loop> which will contain the listening
sockets.

=back

=cut

sub new
{
   my $class = shift;
   my ( %args ) = @_;

   my $self = $class->SUPER::new(
      exists $args{on_request} ? ( on_request => delete $args{on_request} ) : (),
      default_encoding => delete $args{default_encoding} || "UTF-8",
   );

   if( defined $args{handle} ) {
      my $loop = $args{loop} or croak "Require a 'loop' argument";

      $loop->add( $self );

      my $handle = delete $args{handle};

      # IO::Async version 0.27 requires this to support ->sockname method
      bless $handle, "IO::Socket" if ref($handle) eq "GLOB" and defined getsockname($handle);

      $self->configure( handle => $handle );
   }
   elsif( defined $args{service} ) {
      my $loop = $args{loop} or croak "Require a 'loop' argument";

      $loop->add( $self );

      $self->listen(
         %args,

         # listen wants some error handling callbacks. Since this is a
         # constructor it's reasonable to provide default 'croak' ones if
         # they're not supplied
         on_resolve_error => sub { croak "Resolve error $_[0] while constructing a " . __PACKAGE__ },
         on_listen_error  => sub { croak "Cannot listen while constructing a " . __PACKAGE__ },
      );
   }

   return $self;
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_request => CODE

Reference to a handler to call when a new FastCGI request is received.
It will be invoked as

 $on_request->( $fcgi, $request )

where C<$request> will be a new L<FCGI::Async::Request> object.

=item default_encoding => STRING

Sets the default encoding used by all new requests. If not supplied then
C<UTF-8> will apply.

=back

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   if( exists $params{on_request} ) {
      $self->{on_request} = delete $params{on_request};
   }

   if( exists $params{default_encoding} ) {
      $self->{default_encoding} = delete $params{default_encoding};
   }

   $self->SUPER::configure( %params );
}

=head1 METHODS

=cut

=head2 $fcgi->listen( %args )

Start listening for connections on a socket, creating it first if necessary.

This method may be called in either of the following ways. To listen on an
existing socket filehandle:

=over 4

=item handle => IO

An IO handle referring to a listen-mode socket. This is now deprecated; use
the C<handle> key to the C<new> or C<configure> methods instead.

=back

Or, to create the listening socket or sockets:

=over 4

=item service => STRING

Port number or service name to listen on.

=item host => STRING

Optional. If supplied, the hostname will be resolved into a set of addresses,
and one listening socket will be created for each address. If not, then all
available addresses will be used.

=back

This method may also require C<on_listen_error> or C<on_resolve_error>
callbacks for error handling - see L<IO::Async::Listener> for more detail.

=cut

# TODO: Most of this needs to be moved into an abstract Net::Async::Server role
sub listen
{
   my $self = shift;
   my %args = @_;

   if( $args{handle} ) {
      carp "Using 'handle' as a ->listen argument is deprecated; use the ->configure method instead";
      $self->configure( handle => $args{handle} );
   }
   else {
      $self->SUPER::listen( %args, socktype => SOCK_STREAM );
   }
}

sub on_accept
{
   my $self = shift;
   my ( $newS ) = @_;

   my $newreq = FCGI::Async::ClientConnection->new( $newS, $self );

   $self->add_child( $newreq );
}

sub _request_ready
{
   my $self = shift;
   my ( $req ) = @_;

   $self->{on_request}->( $self, $req );
}

sub _default_encoding
{
   my $self = shift;
   return $self->{default_encoding};
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 Limits in FCGI_GET_VALUES

The C<FCGI_GET_VALUES> FastCGI request can enquire of the responder the
maximum number of connections or requests it can support. Because this module
puts no fundamental limit on these values, it will return some arbitrary
numbers. These are given in package variables:

 $FCGI::Async::MAX_CONNS = 1024;
 $FCGI::Async::MAX_REQS  = 1024;

These variables are provided in case the containing application wishes to make
the library return different values in the request. These values are not
actually used by the library, other than to fill in the values in response of
C<FCGI_GET_VALUES>.

=head1 Using a socket on STDIN

When running a local FastCGI responder, the webserver will create a new INET
socket connected to the script's STDIN file handle. To use the socket in this
case, it should be passed as the C<handle> argument.

=head1 SEE ALSO

=over 4

=item *

L<CGI::Fast> - Fast CGI drop-in replacement of L<CGI>; single-threaded,
blocking mode.

=item *

L<http://hoohoo.ncsa.uiuc.edu/cgi/interface.html> - The Common Gateway
Interface Specification

=item *

L<http://www.fastcgi.com/devkit/doc/fcgi-spec.html> - FastCGI Specification

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
