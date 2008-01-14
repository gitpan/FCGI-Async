#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005-2007 -- leonerd@leonerd.org.uk

package FCGI::Async;

use warnings;
use strict;

use base qw( IO::Async::Notifier );

use FCGI::Async::ClientConnection;
use FCGI::Async::Constants;

use IO::Socket::INET;

=head1 NAME

FCGI::Async - Module to allow use of FastCGI asynchronously

=cut

our $VERSION = '0.13';
our $DEBUG = 0;

=head1 SYNOPSIS

This module allows a program to respond to FastCGI requests using an
asynchronous model. It is based on L<IO::Async> and will fully interact with
any program using this base.

 use FCGI::Async;
 use IO::Async::Set::IO_Poll;

 my $fcgi = FCGI::Async->new(
    on_request => sub {
       my ( $fcgi, $req ) = @_;

       # Handle the request here
    }
 );

 my $set = IO::Async::Set::IO_Poll->new();

 $set->add( $fcgi );

 $set->loop_forever;

=cut
    
=head1 FUNCTIONS

=cut

=head2 $fcgi = FCGI::Async->new( %args )

This function returns a new instance of a C<FCGI::Async> object, containing
a master socket to listen on. The constructor returns immediately; it does not
make any blocking calls.

The function operates in one of three ways, depending on arguments 
passed in the C<%args> hash:

=over 4

=item *

Listening on an existing socket.

 socket => $socket

This must be a socket opened in listening mode, derived from C<IO::Socket>, or
any other class that handles the C<fileno> and C<accept> methods in a similar
way.

=item *

Creating a new listening socket.

 port => $port

A new C<IO::Socket::INET> socket will be opened on the given port number. It
will listen on all interfaces, from all addresses.

=item *

Using the socket passed as STDIN from a webserver.

When running a local FastCGI responder, the webserver will create a new INET
socket connected to the script's STDIN file handle. To use the socket in this
case, pass neither of the above options.

=back

The C<%args> hash must also contain a CODE reference to a callback function to
call when a new FastCGI request arrives

 on_request => sub { ... }

or

 on_request => \&handler

This will be passed two parameters; the C<FCGI::Async> container object, and a
new C<FCGI::Async::Request> object representing the specific request.

 $on_request->( $fcgi, $request )

=cut

sub new
{
   my $class = shift;
   my ( %args ) = @_;

   my $socket;

   if( $args{socket} ) {
      $socket = $args{socket};
   }
   elsif( $args{port} ) {
      $socket = IO::Socket::INET->new(
         Type      => SOCK_STREAM,
         LocalPort => $args{port},
         Listen    => 10,
         ReuseAddr => 1,
         Blocking  => 0,
      );
   }
   else {
      $socket = \*STDIN;

      # Rebless it into the IO::Socket::INET space so we can call ->accept()
      # on it
      # TODO - ensure it really is an INET socket first
      $socket = bless $socket, "IO::Socket::INET";
   }

   my $self = $class->SUPER::new( read_handle => $socket );

   warn "You no longer have to supply a 'set' argument to FCGI::Async->new() - it has been ignored"
      if exists $args{set};

   $self->{on_request} = $args{on_request};

   return $self;
}

sub on_read_ready
{
   my $self = shift;

   my $newS = $self->read_handle->accept() or die "Cannot accept() - $!";

   my $newreq = FCGI::Async::ClientConnection->new( $newS, $self );

   $self->add_child( $newreq );
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

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>

=back
