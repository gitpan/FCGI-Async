#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005,2006 -- leonerd@leonerd.org.uk

package FCGI::Async;

use warnings;
use strict;

use base qw( IO::Async::Notifier );

use FCGI::Async::Request;
use FCGI::Async::Constants;

use IO::Socket::INET;

=head1 NAME

FCGI::Async - Module to allow use of FastCGI asynchronously

=cut

our $VERSION = '0.08';
our $DEBUG = 0;

=head1 SYNOPSIS

This module allows a program to respond to FastCGI requests using an
asynchronous model. The program would typically be structured as a C<select()>
loop.

    use FCGI::Async;

    my $fcgi = FCGI::Async->new();
    
    while( 1 ) {
       $fcgi->select();
       # perform non-blocking tasks here
    }

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

   my $set = $args{set};

   defined $set and ref $set and $set->isa( 'IO::Async::Set' ) or
      die "Expected to be passed an IO::Async::Set";

   $set->add( $self );

   $self->{reqs} = [];

   return $self;
}

sub on_read_ready
{
   my $self = shift;

   my $reqs = $self->{reqs};

   my $newS = $self->read_handle->accept() or die "Cannot accept() - $!";

   my $newreq = FCGI::Async::Request->new( $newS, $self );

   push @{$self->{reqs}}, $newreq;

   my $set = $self->{set};
   $set->add( $newreq );
}

=head2 $req = $fcgi->waitingreq

This method obtains a C<FCGI::Async::Request> object that is ready for some
operation to be performed on it. If no request is ready, this method will
return C<undef>.

See L<FCGI::Async::Request> for more details.

=cut

sub waitingreq
{
   my $self = shift;

   my $reqs = $self->{reqs};

   foreach my $req ( @$reqs ) {
      return $req if( $req->ready );
   }

   return undef;
}

sub _removereq
{
   my $self = shift;
   my ( $req ) = @_;

   my $reqs = $self->{reqs};
   my $set  = $self->{set};

   for( my $i = 0; $i < scalar @$reqs; $i++ ) {
      if ( $reqs->[$i] == $req ) {
         $set->remove( $reqs->[$i] );

         splice @$reqs, $i, 1;
         $i--;
      }
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<CGI::Fast> - Fast CGI drop-in replacement of L<CGI>; single-threaded,
blocking mode.

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>

=back
