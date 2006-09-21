package FCGI::Async::Request;

use strict;

use base qw( FCGI::Async );

use FCGI::Async::Constants;

# The largest we'll try to send() down the network at any one time
use constant MAXSENDSIZE => 4096;

# The largest amount of data we can fit in a FastCGI record - MUST NOT
# be greater than 2^16-1
use constant MAXRECORDDATA => 65535;

use POSIX qw( EAGAIN );

sub _debug($)
{
   my ( $message ) = @_;
   warn $message if $FCGI::Async::DEBUG;
}

sub new
{
   my $class = shift;
   my ( $sock, $fcgi ) = @_;

   my $self = {
      S          => $sock,
      fcgi       => $fcgi,
      state      => STATE_NEW,
      stdin      => "",
      stdindone  => 0,
      params     => {},
      paramsdone => 0,
      writebuffer => "",
   };
   bless $self, $class;

   $self->dorecord();

   _debug "Instantiating a new FCGI::Async::Request";

   return $self;
}

sub readrecord
{
   my $self = shift;

   my $rec = $self->readrecheader();

   return undef unless( defined $rec );

   my $content = $self->readbuffer( $rec->{len} );
   $self->readbuffer( $rec->{plen} ); # burn this one up

   $rec->{content} = $content;

   die "Bad record version" unless( $rec->{ver} eq FCGI_VERSION_1 );

   return $rec;
}

sub readrecheader
{
   my $self = shift;

   my $packedheader = $self->readbuffer( 8 );

   return undef unless( defined $packedheader );

   my ( $ver, $type, $reqid, $contentlen, $paddinglen, undef ) = unpack( "ccnncc", $packedheader ); # Requires 8 bytes

   _debug "Have a header ver=$ver type=$type reqid=$reqid len=$contentlen (pad=$paddinglen)";
   my %rec = ( ver   => $ver, 
               type  => $type,
               reqid => $reqid,
               len   => $contentlen,
               plen  => $paddinglen );
   return \%rec;
}

sub readbuffer
{
   my $self = shift;
   my ( $size ) = @_;

   my $S = $self->{S};

   my $buffer = '';
   my $sofar = 0;

   while( $size ) {
      my $ret = sysread( $S, $buffer, $size, $sofar );
      return undef if( $ret == 0 ); # Closed
      die "Cannot sysread() - $!" if( $ret < 0 );
      $size -= $ret;
      $sofar += $ret;
   }

   return $buffer;
}

sub writebuffer
{
   my $self = shift;
   
   my $S = $self->{S};

   my $buffer = $self->{writebuffer};
   my $size   = length( $buffer );
   $size = MAXSENDSIZE if( $size > MAXSENDSIZE );

   _debug "$self is about to syswrite() $size bytes of data";
   my $ret = syswrite( $S, $buffer, $size, 0 );
   my $perror = $!+0;
   my $perrorstr = "$!";

   if( !defined $ret && $perror == EAGAIN ) {
      # Nothing was send, would block. Just return for now
      return;
   }
   
   if( $ret == 0 ) {
      die "Cannot syswrite() - connection closed"; # Closed
   }
   
   if( defined $ret ) {
      # Something was sent
      _debug "$self wrote $ret bytes";
      substr( $buffer, 0, $ret, "" );

      if( length( $buffer ) == 0 and $self->{state} == STATE_PENDINGREMOVE ) {
         _debug "$self has now finished flushing buffer; will now destruct"; 
         my $fcgi = $self->{fcgi};
         $fcgi->removereq( $self );
         return;
      }

      _debug "$self has a buffer of " . ( length $buffer ) . " bytes left";
      $self->{writebuffer} = $buffer;
      return;
   }

   die "Cannot syswrite() - $perrorstr";
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
      $contentlen = MAXRECORDDATA;
   }

   my ( $headbuffer ) = pack( "ccnncc", FCGI_VERSION_1, $rec->{type}, $self->{reqid}, $contentlen, 0, 0 );

   my $buffer = $headbuffer . $content;

   $self->{writebuffer} .= $buffer;

   $self->writebuffer();
}

sub parsenamevalue
{
   my $self = shift;

   my $namelen = unpack( "c", $_[0] );
   if ( $namelen > 0x7f ) {
      # It's a 4byte
      $namelen = unpack( "N", $_[0] ) & 0x7fffffff;
      substr( $_[0], 0, 4 ) = "";
   }
   else {
      substr( $_[0], 0, 1 ) = "";
   }

   my $valuelen = unpack( "c", $_[0] );
   if ( $valuelen > 0x7f ) {
      # It's a 4byte
      $valuelen = unpack( "N", $_[0] ) & 0x7fffffff;
      substr( $_[0], 0, 4 ) = "";
   }
   else {
      substr( $_[0], 0, 1 ) = "";
   }

   my $name = substr( $_[0], 0, $namelen );
   substr( $_[0], 0, $namelen ) = "";

   my $value = substr( $_[0], 0, $valuelen );
   substr( $_[0], 0, $valuelen ) = "";
   
   return( $name, $value );
}

sub parsenamevalues
{
   my $self = shift;
   my ( $buffer ) = @_;

   my %values = ();
   while( $buffer ) {
      my ( $name, $value ) = $self->parsenamevalue( $buffer );
      $values{$name} = $value;
   }

   return \%values;
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
      _debug "$self just received unknown record type";
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
   _debug "$self now in active state for id $self->{reqid} role $role flags $flags";
}

sub incomingrecord_params
{
   my $self = shift;
   my ( $rec ) = @_;

   my $content = $rec->{content};
   my $len     = $rec->{len};

   if( $len ) {
      my $paramshash = $self->parsenamevalues( $content );
      my $p = $self->{params};
      foreach ( keys %$paramshash ) {
         $p->{$_} = $paramshash->{$_};
      }
      _debug "$self now received " . ( scalar %$paramshash ) . " more params";
   }
   else {
      $self->{paramsdone} = 1;
      _debug "$self has now finished params";
   }
}

sub incomingrecord_stdin
{
   my $self = shift;
   my ( $rec ) = @_;

   my $content = $rec->{content};
   my $len     = $rec->{len};

   if( $len ) {
      _debug "$self is now receiving more STDIN";
      $self->{stdin} .= $content;
   }
   else {
      _debug "$self has finished receiving STDIN";
      $self->{stdindone} = 1;
   }
}

sub dorecord
{
   my $self = shift;
   
   my $rec = $self->readrecord;
   $self->incomingrecord( $rec ) if $rec;
}

sub fileno
{
   my $self = shift;
   return fileno( $self->{S} );
}

sub params
{
   my $self = shift;

   my %p = %{$self->{params}};

   return \%p;
}

sub param
{
   my $self = shift;
   my ( $key ) = @_;

   return $self->{params}{$key};
}

sub ready
{
   my $self = shift;

   return ( $self->{stdindone} and 
            $self->{paramsdone} and 
            $self->{state} != STATE_PENDINGREMOVE );
}

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

sub finish
{
   my $self = shift;

   $self->print_stdout( "" );
   $self->end_request( 0, FCGI_REQUEST_COMPLETE );

   my $fcgi = $self->{fcgi};

   if ( length( $self->{writebuffer} ) > 0 ) {
      $self->{state} = STATE_PENDINGREMOVE;
   }
   else {
      $fcgi->removereq( $self );
   }
}

sub pre_select
{
   my $self = shift;
   my ( $readref, $writeref, $exceptref, $timeref ) = @_;

   my $fileno = $self->fileno;

   vec( $$readref, $fileno, 1 ) = 1;

   if( length( $self->{writebuffer} ) > 0 ) {
      _debug "$self has writebuffer - adding to writevec";
      vec( $$writeref, $fileno, 1 ) = 1;
   }
}

sub post_select
{
   my $self = shift;
   my ( $readvec, $writevec, $exceptvec ) = @_;

   my $fileno = $self->fileno;

   if( vec( $readvec, $fileno, 1 ) ) {
      $self->dorecord();
   }

   if( vec( $writevec, $fileno, 1 ) ) {
      _debug "$self is writable - will try resending output";
      $self->writebuffer();
   }
}

# Keep perl happy; keep Britain tidy
1;
