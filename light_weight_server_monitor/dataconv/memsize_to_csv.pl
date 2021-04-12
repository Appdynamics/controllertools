#!/usr/bin/env perl

# convert monX.sh script memsize() function file output to CSV, initial part of pipeline for TSDB viewing

# call as:
# perl scripts/memsize_to_csv.pl < XXXXX_memsize_yyy.txt 

use warnings;
use strict;
use Getopt::Long;

sub usage {
   return "Usage: $0 [-u <comma separated unit>]		# output as CSV\n";
}

{
   my ($minc, $maxc) = (9999999,0);                     # global variable private to check() i.e. C static variable
   my $dataversion;					# initially undefined then set to 1 or 2 or ... used to signal version specific actions

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
      my $lastrow_version = $version_in;				# sensible default value... might need over writing

      if (defined( $dataversion )) {					# changing data versions with different columns should not flag up as an error
	 if ($dataversion != $version_in) {
            reset_limits();
	    $lastrow_version = $dataversion;				# save prior version to be able to return it
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
my %args;
GetOptions(\%args, "unit=s") or die usage();
my ($gf_rss, $gf_vsz, $gf_swap, $mysql_rss, $mysql_vsz, $mysql_swap, $cols);

$cols = 3; 			# assume input comes from mon30 initially...
my $firstrow = 1;
my $lastrow_version;
while ( defined( my $row = <STDIN> ) ) {
   $row =~ s/\015?\012/\n/g;         			# normalise Windows CRLF to just LF
   next if $row =~ m/UNABLE_TO_READ/;			# /proc read error
   next if $row =~ m/_RUNNING/;				# process not currently running
   my @column = split(" ", $row);
   
   #
   # over the years the memory measurement needs have changed and so this parsing for backwards compatibility now looks messy
   # Currently support all monX versions and will continue to do that
   if ($column[0] =~ m/^\d{4,4}-\d{2,2}-\d{2,2}T\d{2,2}:\d{2,2}/) {	# first column a timestamp => mon31+ format
      # DATA VERSION == 2
      $lastrow_version = check(scalar @column, $row, 2);		# sanity check else die

      if ($firstrow == 1 || $lastrow_version != 2) {			# output header row at very beginning else whenever data versions change
	 print "timestamp,node,@{[ join(q{,},map { s/=.*$//r } @column[2..$#column]) ]}\n";
	 $firstrow = 0;
      }
      print "@{[ join(q{,},map { s/^.*=//r } @column) ]}\n";
      $lastrow_version = 2;

   } else {								# pre mon31 formats 
      # DATA VERSION == 1
      $lastrow_version = check(scalar @column, $row, 1);		# sanity check else die

      # break following into 3 separate matches to prevent one mis-match causing all others to not match either
      my ($gf) = $row =~ m/^gf_rss_[^=]+=(\S+)\s+mysql_rss/;	
      my ($mysql) = $row =~ m/\s+mysql_rss_[^=]+=(\S+)\s/;
      my ($ts) = $row =~ m/\s(\S+)$/;

      if (not (defined $gf) || $gf =~ m/^NO_GLASSFISH_RUNNING$/) {
	 $gf_rss = 0;
	 $gf_vsz = 0;
	 $gf_swap = undef;
      } else {
	 ($gf_rss, $gf_vsz) = $gf =~ m/^(\d+)m,(\d+)m/;
	 ($gf_swap) = $gf =~ m/^\d+m,\d+m,(\d+)m$/;
      }
      defined $gf_rss && defined $gf_vsz or die "bad sizes for Glassfish memory: $row";

      # bit ugly way to determine expectation for 2 or 3 cols per GF or MySQL
      if ($firstrow == 1 || $lastrow_version != 1) {			# set expected # columns from gf values in 1st row
	 $cols = (defined $gf_swap)? 3 : 2;
      } else {
	 die "bad sizes for Glassfish memory: $row" if (($cols == 2 && defined $gf_swap) || ($cols == 3 && $gf_vsz > 0 && ! defined $gf_swap));
      }

      if (not (defined $mysql) || $mysql =~ m/^NO_MYSQL_RUNNING$/) {
	 $mysql_rss = 0;
	 $mysql_vsz = 0;
	 $mysql_swap = undef;
      } else {
	 ($mysql_rss, $mysql_vsz) = $mysql =~ m/^(\d+)m,(\d+)m/;
	 ($mysql_swap) = $mysql =~ m/^\d+m,\d+m,(\d+)m$/;
      }
      defined $mysql_rss && defined $mysql_rss or die "bad sizes for MySQL memory: $row";
      die "bad sizes for MySQL memory: $row" if (($cols == 2 && defined $mysql_swap) || ($cols == 3 && $mysql_vsz > 0 && ! defined $mysql_swap));
      
      my ($tsm) = $ts =~ m/^(\d+-\d+-\d+T\d+:\d+)/;
      defined $tsm or die "$0: unable to get ISO date from '$row'";

      if ($firstrow == 1 || $lastrow_version != 1) {	# compile header from column identifiers
	 my ($tag1,$extn11,$extn12,$extn13,$tag2,$extn21,$extn22,$extn23);
	 if ($cols == 3) {
	    ($tag1,$extn11,$extn12,$extn13,$tag2,$extn21,$extn22,$extn23) = $row =~ m/^([^_]+)_([^_]+)_([^_]+)_([^_]+)=\S+\s([^_]+)_([^_]+)_([^_]+)_([^_]+)=/;
	    defined $tag1 && defined $extn23 or die "$0: unable to build header from '$row'";
	 } else {
	    ($tag1,$extn11,$extn12,$tag2,$extn21,$extn22) = $row =~ m/^([^_]+)_([^_]+)_([^_]+)=\S+\s([^_]+)_([^_]+)_([^_]+)=/;
	    defined $tag1 && defined $extn22 or die "$0: unable to build header from '$row'";
	 }

	 my ($tag1unit,$tag2unit);
	 if (exists $args{unit}) {
	    ($tag1unit,$tag2unit) = "$args{unit}" =~ m/^([^,]*),(.*)$/;
	 } else {
	    ($tag1unit,$tag2unit) = "$gf $mysql" =~ m/^\d+([^,]*),\S+\s\d+([^,]*),/;
	 }
	 $tag1unit = (defined $tag1unit)? "_$tag1unit" : "_m";	# default units to 'm' ie MB
	 $tag2unit = (defined $tag2unit)? "_$tag2unit" : "_m";	# default units to 'm' ie MB

	 my $header;
	 if ($cols == 3) {
	    $header = sprintf("timestamp,%s_%s%s,%s_%s%s,%s_%s%s,%s_%s%s,%s_%s%s,%s_%s%s\n", 
			   $tag1, $extn11, $tag1unit,
			   $tag1, $extn12, $tag1unit,
			   $tag1, $extn13, $tag1unit,
			   $tag2, $extn21, $tag2unit,
			   $tag2, $extn22, $tag2unit,
			   $tag2, $extn23, $tag2unit);
	 } else {
	    $header = sprintf("timestamp,%s_%s%s,%s_%s%s,%s_%s%s,%s_%s%s\n", 
			   $tag1, $extn11, $tag1unit,
			   $tag1, $extn12, $tag1unit,
			   $tag2, $extn21, $tag2unit,
			   $tag2, $extn22, $tag2unit);
	 }
	 print "$header";
	 $firstrow = 0;
      }

      if ($cols == 3) {
	 print sprintf("%s,%d,%d,%d,%d,%d,%d\n", 
			   $ts, $gf_rss, $gf_vsz, (defined $gf_swap)? $gf_swap : 0, 
			   $mysql_rss, $mysql_vsz, (defined $mysql_swap)? $mysql_swap : 0);
      } else {
	 print sprintf("%s,%d,%d,%d,%d\n", 
			   $ts, $gf_rss, $gf_vsz, $mysql_rss, $mysql_vsz);
      }
   }
}
