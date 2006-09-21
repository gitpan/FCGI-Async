package FCGI::Async;

use warnings;
use strict;

use FCGI::Async::Request;
use FCGI::Async::Constants;

use IO::Socket::INET;

=head1 NAME

FCGI::Async - Module to allow use of FastCGI asynchronously

=head1 VERSION

Version 0.03

=cut

our $VERSION = '0.06';
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

=head2 new

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

   my $self = { 
      S    => $socket, 
      reqs => [],
   };

   return bless $self, $class;
}

=head2 pre_select

=cut

sub pre_select
{
   my $self = shift;
   my ( $readref, $writeref, $exceptref, $timeref ) = @_;

   my $S = $self->{S};
   my $Sfileno = $S->fileno;
   my $reqs = $self->{reqs};

   vec( $$readref, $Sfileno, 1 ) = 1; # set STDIN

   foreach my $req ( @$reqs ) {
      $req->pre_select( $readref, $writeref, $exceptref, $timeref );
   }
}

=head2 post_select

=cut

sub post_select
{
   my $self = shift;
   my ( $readvec, $writevec, $exceptvec ) = @_;

   my $S = $self->{S};
   my $Sfileno = $S->fileno;
   my $reqs = $self->{reqs};

   foreach my $req ( @$reqs ) {
      $req->post_select( $readvec, $writevec, $exceptvec );
   }

   if ( vec( $readvec, $Sfileno, 1 ) ) {
      vec( $readvec, $Sfileno, 1 ) = 0;

      my $newS = $S->accept() or
         die "Cannot accept() - $!";

      my $newreq = FCGI::Async::Request->new( $newS, $self );

      push @{$self->{reqs}}, $newreq;
   }
}

=head2 select

=cut

sub select
{
   my $self = shift;

   my $rvec = '';
   my $wvec = '';
   my $evec = '';
   my $timeout = undef;

   $self->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

   my $ret = select( my $rout = $rvec, my $wout = $wvec, my $eout = $evec, $timeout );

   $self->post_select( $rout, $wout, $eout );

   return $ret;
}

=head2 waitingreq

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

sub removereq
{
   my $self = shift;
   my ( $req ) = @_;

   my $reqs = $self->{reqs};

   for( my $i = 0; $i < scalar @$reqs; $i++ ) {
      if ( $reqs->[$i] == $req ) {
         splice @$reqs, $i, 1;
         $i--;
      }
   }
}

=head1 AUTHOR

Paul Evans, C<< <leonerd at leonerd.org.uk> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-fcgi-async at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=FCGI-Async>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc FCGI::Async

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/FCGI-Async>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/FCGI-Async>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=FCGI-Async>

=item * Search CPAN

L<http://search.cpan.org/dist/FCGI-Async>

=back

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

Copyright 2005 Paul Evans, all rights reserved.

This program is released under the following license: GPLv2

=cut

# Keep perl happy; keep Britain tidy
1;
