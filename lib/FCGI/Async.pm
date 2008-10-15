#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005-2008 -- leonerd@leonerd.org.uk

package FCGI::Async;

use warnings;
use strict;

use Carp;

use base qw( IO::Async::Notifier );

use FCGI::Async::ClientConnection;
use FCGI::Async::Constants;

use IO::Socket::INET;

=head1 NAME

FCGI::Async - Module to allow use of FastCGI asynchronously

=cut

our $VERSION = '0.15';

=head1 SYNOPSIS

B<NOTE>: The constructor API of this module has changed since version 0.13!

This module allows a program to respond to FastCGI requests using an
asynchronous model. It is based on L<IO::Async> and will fully interact with
any program using this base.

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

=cut
    
=head1 CONSTRUCTOR

=cut

=head2 $fcgi = FCGI::Async->new( %args )

This function returns a new instance of a C<FCGI::Async> object.

The C<%args> hash must contain the following:

=over 4

=item on_request => CODE

Reference to a handler to call when a new FastCGI request is received.
It will be invoked as

 $on_request->( $fcgi, $request )

where C<$request> will be a new L<FCGI::Async::Request> object.

=back

If either a C<handle> or C<service> argument are passed to the constructor,
then the newly-created object is added to the given C<IO::Async::Loop>, then
the C<listen> method is invoked, passing the entire C<%args> hash to it. For
more detail, see the C<listen> method below.

If of the above arguments are given, then a C<IO::Async::Loop> must also be
provided:

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

   my $self = $class->SUPER::new();

   if( $args{socket} ) {
      carp "'socket' is now deprecated; use 'handle' instead";
      $args{handle} = delete $args{socket};
   }

   if( $args{port} ) {
      carp "'port' is now deprecated; use 'service' instead";
      $args{service} = delete $args{port};
   }

   if( defined $args{handle} or defined $args{service} ) {
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

   $self->{on_request} = $args{on_request};

   return $self;
}

=head1 METHODS

=cut

=head2 $fcgi->listen( %args )

Start listening for connections on a socket, creating it first if necessary.

This method may be called in either of the following ways. To listen on an
existing socket filehandle:

=over 4

=item handle => IO

An IO handle referring to a listen-mode socket.

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

   my $loop = $self->get_loop or croak "Cannot listen without a Loop";

   $loop->listen(
      socktype => SOCK_STREAM,
      %args,

      on_accept => sub {
         my ( $newS ) = @_;

         my $newreq = FCGI::Async::ClientConnection->new( $newS, $self );

         $self->add_child( $newreq );
      }
   );
}

sub _request_ready
{
   my $self = shift;
   my ( $req ) = @_;

   $self->{on_request}->( $self, $req );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 Using a socket on STDIN

When running a local FastCGI responder, the webserver will create a new INET
socket connected to the script's STDIN file handle. To use the socket in this
case, it should be passed as the 'socket'

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

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
