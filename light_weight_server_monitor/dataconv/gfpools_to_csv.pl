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

############################################################################
# Main body
############################################################################

$/ = "#section "; 		# read in blocks delimited by this string

while (defined (my $block = <STDIN>)) {
   my ($section_name) = $block =~ m/^\s*(\S+):/;
   defined $section_name or next;		# skip first section delimiter
   next if $section_name eq 'error';
   $block =~ s/^.*:$//m;			# delete first row
   for my $row ( split(/^/,$block) ) {
      next if $row =~ m/^\s*$/;
      next if $row =~ m/^#section/;
      print $row;
   }
}
