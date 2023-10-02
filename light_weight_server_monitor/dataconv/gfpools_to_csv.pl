#!/usr/bin/env perl

#
# converts multi-format CSV blocks within gftools monitor output into input acceptable for
# csv_to_tsdb.pl
#
use strict;
use warnings;

use Getopt::Long;

sub usage {
   return "Usage: $0";
}

{
   my ($minc, $maxc) = (9999999,0);                     # global variable private to check() i.e. C static variable
   sub check {
      my $nf = $_[0] // die "check: needs 1st arg";
      my $row = $_[1] // die "check: needs 2nd arg";
   
      $maxc = $nf if $nf > $maxc;
      $minc = $nf if $nf < $minc;
      die "ERROR: inconsistent column count (maxc=$maxc,minc=$minc) in row: $row" if $maxc != $minc;
   }
   sub init_check {
      $minc = $_[0] // die "check: needs minc arg1";
      $maxc = $_[1] // die "check: needs maxc arg2";
   }
}

############################################################################
# Main body
############################################################################

$/ = "#section "; 		# read in blocks delimited by this string

while (defined (my $block = <STDIN>)) {
   my ($section_name) = $block =~ m/^\s*(\S+):/;
   defined $section_name or next;		# skip first section delimiter
   next if $section_name eq 'error';
   $block =~ s/\015?\012/\n/g;			# normalise Windows CRLF to just LF
   $block =~ s/^.*:$//m;			# delete first row
   for my $row ( split(/^/,$block) ) {
      next if $row =~ m/^\s*$/;
      next if $row =~ m/^#section/;
      init_check(9999999,0) if ($row =~ m/(?:timestamp,)|(?:,timestamp)/i); 	# assume that this row is a header and possibly start of new sequence of rows
      check(scalar split(",", $row),$row);		# sanity check else die
      print $row;
   }
}
