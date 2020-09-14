#!/usr/bin/env perl

#
# convert current monX numabuddyrefs to CSV
#

use strict;
use warnings;

use Getopt::Long;

sub usage {
   return "Usage: $0";
}

sub print_buddyinfo_csv {
   my $data = $_[0] // die "ERROR: @{[(caller(0))[3]]}: needs first string arg";
   my $datetime = $_[1] // die "ERROR: @{[(caller(0))[3]]}: needs 2nd datetime arg";
   local $/ = "\n";

   open( my $fh, "<", \$data ) || die "ERROR: @{[(caller(0))[3]]} unable to open scalar for reading: $!";
   print "timestamp,node,zone,order0,order1,order2,order3,order4,order5,order6,order7,order8,order9,order10\n";
   while ( defined( my $row = <$fh> ) ) {
      my ($n,$z) = $row =~ m/^Node\s+(\S+),\s+zone\s+(\S+)\s+/gc;	# remember last match position for next match
      my @vals = $row =~ m/(\S+)/g;					# continue matching from last match position
      print "$datetime,$n,$z,@{[join(q{,},@vals)]}\n";
   }
   close( $fh );
}

sub print_procvmstat_csv {
   my $data = $_[0] // die "ERROR: @{[(caller(0))[3]]}: needs first string arg";
   my $datetime = $_[1] // die "ERROR: @{[(caller(0))[3]]}: needs 2nd datetime arg";
   my (%vals, @labels);
   local $/ = "\n";

   open( my $fh, "<", \$data ) || die "ERROR: @{[(caller(0))[3]]} unable to open scalar for reading: $!";
   while ( defined( my $row = <$fh> ) ) {
      my ($k, $v) = $row =~ m/^(\S+)\s+(\S+)/;
      defined $k && defined $v || die "ERROR: @{[(caller(0))[3]]}: unable to find key,value pairs within: $row";
      push @labels, $k;
      $vals{$k} = $v;
   }
   print "timestamp,@{[join(q{,},@labels)]}\n";
   print "$datetime,@{[join(q{,},@vals{@labels})]}\n";
   close( $fh );
}

sub print_numastat_csv {
   my $data = $_[0] // die "ERROR: @{[(caller(0))[3]]}: needs first string arg";
   my $datetime = $_[1] // die "ERROR: @{[(caller(0))[3]]}: needs 2nd datetime arg";
   my (@nodes, @labels, %vals, $ncount, @numalabels);
   my ($nodesuncounted, $numarows) = (1, 0);
   local $/ = "\n";


   open( my $fh, "<", \$data ) || die "ERROR: @{[(caller(0))[3]]} unable to open scalar for reading: $!";
   while ( defined( my $row = <$fh> ) ) {
      next if $row =~ m/^\s*$/;
      next if $row =~ m/^Per-node/;
      if ($row =~ m/^\s+Node /) { 	
	 if ($nodesuncounted == 0) {		# found block of NUMA rows
	    $numarows = 1;
	    next;
	 }
         @nodes = $row =~ m/(\d+)/g;		# match all integers alone including final total column
         $nodesuncounted = 0;
	 next;
      }
      next if $row =~ m/-----/;
      my ($l) = $row =~ m/^(\S+)\s+/;
      if ($numarows == 0) {			# current row is non-NUMA hit statistic - so can extend label with _mb
         push @labels, $l;
      } else {					# current row is a pure NUMA hit statistic - so leave label alone
         push @numalabels, $l;
      }
      my @v = $row =~ m/(\d+)/g;
      defined $l || die "ERROR: undefined label for numastat block at $datetime in row: $row";
      @vals{ map { "${_} $l" } @nodes } = @v[0..$#nodes];
   }
   # OpenTSDB does not accept parentheses in column names...
   print "timestamp,node,@{[join(q{,},map { $_ =~  tr/(/_/; $_ =~  tr/)//d; $_ } map { qq/${_}_mb/ } @labels)]},@{[join(q{,},@numalabels)]}\n";
   for my $n ( @nodes ) {
      print "$datetime,$n,@{[join(q{,},@vals{ map { qq/$n $_/ } (@labels,@numalabels) })]}\n";
   }
   close( $fh );
}

############################################################################
# Main body
############################################################################

my $delim = "datetime: ";
			# GLOBAL setting
$/ = $delim;          	# read in blocks delimited by this string
			# -- will need to undo this within subroutines to ensure their default line delimiter is in effect

while (defined (my $block = <STDIN>)) {
   next if $block =~ m/^$delim$/;		# remove delimiter only row, usually first
   my ($datetime) = $block =~ m/^(\d\d\d\d-\S+)/;
   defined $datetime || die "unable to read current datetime within: $block";
   $block =~ s/^.*?$//m;	# delete datetime header row

   my ($buddyinfo, $procvmstat, $numastat) = $block =~ m/#section buddyinfo:\s(.*?)\s#section procvmstat:\s(.*?)\s#section numastat:\s(.*?)\s(?:$delim)?\Z/ms;
   defined $buddyinfo || die "ERROR: buddyinfo section not read within: $block";
   defined $procvmstat || die "ERROR: procvmstat section not read within: $block";
   defined $numastat || die "ERROR: numastat section not read within: $block";

   print_buddyinfo_csv( $buddyinfo, $datetime);
   print_procvmstat_csv( $procvmstat, $datetime );
   print_numastat_csv( $numastat, $datetime );
}
