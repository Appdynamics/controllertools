#!/usr/bin/env perl

# convert monX procio monitor output to CSV
# Call as:
#  perl procio_to_csv.pl < XXXXX_procio_*txt

use warnings;
use strict;

{
	my ($minc, $maxc) = (9999999,0);                     # global variable private to check() i.e. C static variable
	sub check {
		my $nf = $_[0] // die "check: needs 1st arg";
		my $row = $_[1] // die "check: needs 2nd arg";
		
		$maxc = $nf if $nf > $maxc; 
		$minc = $nf if $nf < $minc;
		die "ERROR: inconsistent column count (maxc=$maxc,minc=$minc) in row: $row" if $maxc != $minc;
	}
}

############################################################################
# Main body
############################################################################
my $firstrow = 1;
while ( defined( my $row = <STDIN> ) ) {
	$row =~ s/\015?\012/\n/g; 			# normalise Windows CRLF to just LF
	next if $row =~ m/UNABLE_TO_READ/;		# /proc read error
	next if $row =~ m/_RUNNING/;			# process not currently running
	my @column = split(" ", $row);
	check(scalar @column, $row);			# sanity check else die - output buffering issues?

	if ($firstrow == 1) {
		print "timestamp,node,@{[ join(q{,},map { s/=.*$//r } @column[2..$#column]) ]}\n";
		$firstrow = 0;
	}
	print "@{[ join(q{,},map { s/^.*=//r } @column) ]}\n";
}
