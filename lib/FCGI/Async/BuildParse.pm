#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2005-2009 -- leonerd@leonerd.org.uk

package # hide from CPAN
   FCGI::Async::BuildParse;

use strict;
use warnings;

use FCGI::Async::Constants;

# This package does not provide an object class, nor exports any methods. It
# exists simply to store some lowlevel buffer building/parsing functions to
# keep the FCGI::Async::Request class clean

sub build_record
{
   my ( $rec, $content ) = @_;
   
   my $contentlen = length $content;

   my ( $headbuffer ) = pack( "ccnncc", FCGI_VERSION_1, $rec->{type}, $rec->{reqid}, $contentlen, 0, 0 );

   return $headbuffer . $content;
}

sub parse_record_header
{
   my ( $headbuffer ) = @_;

   my ( $ver, $type, $reqid, $contentlen, $paddinglen, undef ) = unpack( "ccnncc", $headbuffer );

   my %rec = ( ver   => $ver, 
               type  => $type,
               reqid => $reqid,
               len   => $contentlen,
               plen  => $paddinglen );
   return \%rec;
}

sub build_namevalue
{
   my ( $name, $value ) = @_;

   my $namelen = length $name;
   my $valuelen = length $value;

   my $ret = "";

   if( $namelen > 0x7f ) {
      $ret .= pack( "N", $namelen | 0x80000000 );
   }
   else {
      $ret .= pack( "C", $namelen );
   }

   if( $valuelen > 0x7f ) {
      $ret .= pack( "N", $valuelen | 0x80000000 );
   }
   else {
      $ret .= pack( "C", $valuelen );
   }

   $ret .= $name;

   $ret .= $value;

   return $ret;
}

sub parse_namevalue
{
   # THIS FUNCTION MODIFIES $_[0]

   my $namelen = unpack( "C", $_[0] );
   if ( $namelen > 0x7f ) {
      # It's a 4byte
      $namelen = unpack( "N", $_[0] ) & 0x7fffffff;
      substr( $_[0], 0, 4 ) = "";
   }
   else {
      substr( $_[0], 0, 1 ) = "";
   }

   my $valuelen = unpack( "C", $_[0] );
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

sub parse_namevalues
{
   my ( $buffer ) = @_;

   my %values = ();
   while( $buffer ) {
      my ( $name, $value ) = parse_namevalue( $buffer );
      $values{$name} = $value;
   }

   return \%values;
}

# Keep perl happy; keep Britain tidy
1;
