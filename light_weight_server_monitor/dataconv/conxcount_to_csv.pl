#!/usr/bin/env perl

# single pass version of port_count_to_csv.pl that converts port_count monitor output to CSV
# ASSUMPTIONS:
# - only State fields possible are as notated in: https://linux.die.net/man/8/netstat

use warnings;
use strict;
use Getopt::Long;

# use Docs to determine total possible set of netstat states - saves 1 pass of
# input data at risk of being out of date over time.
# Get all possible states from: https://linux.die.net/man/8/netstat
# Ensure the timestamp column is first column - required for later TSDB conversion.
# Ensure extra TOTAL column is included.
sub get_col_header {
   return qw/timestamp port
   		ESTABLISHED SYN_SENT SYN_RECV FIN_WAIT1 FIN_WAIT2 TIME_WAIT
		CLOSED CLOSE_WAIT LAST_ACK LISTEN CLOSING UNKNOWN
		TOTAL/;
}

sub usage {
   return "Usage: $0            # output as CSV\n";
}

############################################################################
# Main body
############################################################################

my @col_header = get_col_header();
print join(",", @col_header),"\n";	# output CSV header

while (defined( my $row = <STDIN> )) {
   $row =~ s/\015?\012/\n/g;				# normalise Windows CRLF to just LF
   my ($svals,$ts) = $row =~ m/^([^\t]+)\s+(\S+)$/;	# grab TS
   defined $svals && defined $ts or die "unable to parse row: $row";

   my @this_labels = map { my ($l,undef)=split(/=/,$_); $l } split(/,/, $svals); # excluding TS
   my @this_vals = map { my (undef,$v)=split(/=/,$_); $v } split(/,/, $svals); # excluding TS

   my %metric_cols;
   @metric_cols{ @col_header } = (0) x scalar( @col_header ); 	# pre-fill with zero
   $metric_cols{ timestamp } = $ts;				# plug in special TS
   @metric_cols{ @this_labels } = @this_vals;

   print join(q{,}, @metric_cols{ @col_header }),"\n";
}
