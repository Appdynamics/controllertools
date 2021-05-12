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

{
   my ($minc, $maxc) = (9999999,0);                     # global variable private to check() i.e. C static variable
   my $dataversion;                                     # initially undefined then set to 1 or 2 or ... used to signal version specific actions

   sub reset_limits {
      $minc = 9999999;
      $maxc = 0;
   }

   # check whether column counts remain consistent except when data versions change.
   # return the data version number prior to call. Allows checks for version changes.
   sub check {
      my $nf = $_[0] // die "@{[(caller(0))[3]]}: needs 1st arg";
      my $row = $_[1] // die "@{[(caller(0))[3]]}: needs 2nd arg";
      my $version_in = $_[2] // die "@{[(caller(0))[3]]}: needs 3rd arg";
      my $lastrow_version = $version_in;                                # sensible default value... might need over writing

      if (defined( $dataversion )) {                                    # changing data versions with different columns should not flag up as an error
         if ($dataversion != $version_in) {
            reset_limits();
            $lastrow_version = $dataversion;                            # save prior version to be able to return it
            $dataversion = $version_in;
         }
      } else {
         $dataversion = $version_in;
      }

      $maxc = $nf if $nf > $maxc; 
      $minc = $nf if $nf < $minc;
      die "ERROR: inconsistent column count (maxc=$maxc,minc=$minc) in row: $row" if $maxc != $minc;

      return $lastrow_version;
   }
}  

############################################################################
# Main body
############################################################################

my (%array, $atrow1, @labels, @values, @column, $nf, $lastrow_version, $col1);

$atrow1 = 1;
while ( defined( my $row = <STDIN> ) ) {
	$row =~ s/\015?\012/\n/g;         	# normalise Windows CRLF to just LF
   	next if $row =~ m/timed out/;		# skip error row
   	next if $row =~ m/call failed/; 	# skip error row

	$col1 = (split(/,/, $row, 2))[0];
   	if ($col1 =~ m/^\w+=\d+$/) { 	# first col a Label=Value pair => VERSION 1 format (pre mon33.sh)
   		my $DATA_VERSION = 1;
		$lastrow_version = check(scalar split(" ", $row), $row, $DATA_VERSION);	# column count based error check

   		my ($svals,$ts) = $row =~ m/^([^\t]+)\s+(\S+)$/;
   		defined $svals && defined $ts or die "unable to parse row: $row";
   		if ( $ts !~ m/^\d\d\d\d-\d\d-\d\dT/ ) { # skip error rows when DB unavailable
      			print STDERR "skipping row: $row";
      			next;
   		}

		@values = map { my (undef,$v)=split(/=/,$_); $v } split(/,/, $svals);
		unshift @values, $ts;	# stuff timestamp onto LHS of array

		if ($atrow1 == 1 || $lastrow_version != $DATA_VERSION) {	# output header row at very beginning else whenever data versions change
			@labels = map { my ($l,undef)=split(/=/,$_); $l } split(/,/, $svals);
			print "timestamp,@{[join(',',@labels)]}\n";

			$atrow1 = 0;		# avoid this block in future
	   	}
	   
	   	print "@{[join(',',@values)]}\n";
		$lastrow_version = $DATA_VERSION;
   	} else {						# VERSION 2 format mon33+
   		my $DATA_VERSION = 2;
		check(scalar split(/,/, $row), $row, $DATA_VERSION);		# column count based error check
		
		# if this data version follows a different one, then simply output what is - no need to generate a header row
		print "$row";
		$lastrow_version = $DATA_VERSION;
   	}
}
