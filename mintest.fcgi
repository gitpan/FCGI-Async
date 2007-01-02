#!/usr/bin/perl -w

use FCGI::Async;

my $count = 0;
my $fcgi = FCGI::Async->new();

sub process_request($)
{
   my ( $req ) = @_;

   my $env = $req->params();

   my $path   = $env->{PATH_INFO} || "/";
   my $qs     = $env->{QUERY_STRING};
   my $method = $env->{REQUEST_METHOD} || "GET";

   my $page = <<EOF;
<html>
 <head>
  <title>FCGI::Async testing page</title>
 </head>
 <body>
  <h1>Path</h1><pre>$path</pre>
  <h2>Query String</h2><pre>$qs</pre>
  <h2>Method</h2><pre>$method</pre>
 </body>
</html>
EOF

   $req->print_stdout(
      "Content-type: text/html\r\n" .
      "Content-length: " . length( $page ) . "\r\n" .
      "\r\n" .
      $page . "\r\n"
   );

   $req->finish();
}

while( 1 ) {
   my $ret = $fcgi->select();

   die "FCGI::Async->select() returned $!" unless( $ret > 0 );

   while( my $req = $fcgi->waitingreq ) {
      process_request( $req );
   }
}
