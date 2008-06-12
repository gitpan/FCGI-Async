package t::lib::TestFCGI;

use strict;

use base qw( Exporter );
our @EXPORT = qw(
   fcgi_trans

   make_server_sock
   connect_client_sock
);

use IO::Socket::INET;

# This test code gets scary to write without effectively writing our
# own FastCGI client implementation. Without doing that, the best thing we can
# do is provide a little helper function to build FastCGI transaction records.

sub fcgi_trans
{
   my %args = @_;

   $args{version} ||= 1;

   my $data = $args{data};
   my $len = length $data;

   #             version type         id         length padlen reserved
   return pack( "C       C            n          n      C      C",
                1,       $args{type}, $args{id}, $len,  0,     0 )
          .
          $data;
}

sub make_server_sock
{
   # Be polite, and only ask to bind to localhost, rather than default of 
   # anything. Also, OpenBSD seems to get upset if we don't, because sockname
   # will be a broadcast address, that the subsequent connect() won't like

   my $S = IO::Socket::INET->new(
      Type      => SOCK_STREAM,
      Listen    => 10,
      LocalAddr => '127.0.0.1',
      ReuseAddr => 1,
      Blocking  => 0,
   );

   defined $S or die "Unable to create socket - $!";

   my $selfaddr = $S->sockname;
   defined $selfaddr or die "Unable to get sockname - $!";

   return ( $S, $selfaddr );
}

sub connect_client_sock
{
   my ( $selfaddr ) = @_;

   my $C = IO::Socket::INET->new(
      Type     => SOCK_STREAM,
   );
   defined $C or die "Unable to create client socket - $!";

   # Normal blocking connect so we can be sure it's done
   $C->connect( $selfaddr ) or die "Unable to connect socket - $!";

   $C->blocking(0);

   return $C;
}

1;
