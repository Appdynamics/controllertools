#!/usr/bin/env perl

# convert monX.sh dbvars function output to CSV ready for csv_to_tsdb.pl
# Call as:
#  perl scripts/dbvars_to_csv.pl < XXXXX_dbvars*.txt

use warnings;
use strict;
use Getopt::Long;

sub usage {
   return "Usage: $0            # output as CSV\n";
}

############################################################################
# Main body
############################################################################

my (%array, $atrow1, @labels, @values);

$atrow1 = 1;
while ( defined( my $row = <STDIN> ) ) {
   $row =~ s/\015?\012/\n/g;         # normalise Windows CRLF to just LF
   my ($svals,$ts) = $row =~ m/^([^\t]+)\s+(\S+)$/;
   defined $svals && defined $ts or die "unable to parse first row: $row";
   if ( $ts !~ m/^\d\d\d\d-\d\d-\d\dT/ ) { # skip error rows when DB unavailable
      print STDERR "skipping row: $row";
      next;
   }

# %array = map { my ($l,$v)=split(/=/,$_); $l => $v } split(/,/, $svals);
   @values = map { my (undef,$v)=split(/=/,$_); $v } split(/,/, $svals);
   unshift @values, $ts;	# stuff timestamp onto LHS of array

   if ($atrow1 == 1) { 		# output header row 
      @labels = map { my ($l,undef)=split(/=/,$_); $l } split(/,/, $svals);
      print "timestamp,@{[join(',',@labels)]}\n";

      $atrow1 = 0;		# avoid this block in future
   }

   print "@{[join(',',@values)]}\n";
}
