#!/usr/bin/env perl

# convert uploaded slowlogmetric.pl output to CSV
#
# Often get multiple rows for same timestamp that correspond to portions of the
# same metric insert buffer. There are 4 partitions in that buffer that get inserted
# at the same time.
# In order to plot reliably, need to optionally expand out the buffer number so that averaging does
# not hide terrible spikes in the elapsed times.

use strict;
use warnings;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';

use POSIX qw( tzset mktime );

# parse epoch from string such as:
# 2015-01-19T16:23:28 ...
sub get_epoch_from_iso {
   my $row = $_[0];
   defined $row or die "get_epoch_from_iso: needs string arg";

   my ($ldate) = $row =~ m/^(\d{4,4}-\d{2,2}-\d{2,2}T\d{2,2}:\d{2,2}:\d{2,2})/;
   defined $ldate or die "busted date for row: $row";
   my ($y,$mon,$d,$h,$m,$s) = $ldate =~ m/(\d{4,4})-(\d{2,2})-(\d{2,2})T(\d{2,2}):(\d{2,2}):(\d{2,2})/;
   defined $d && defined $mon && defined $y or die "bad date for row: $row";
   defined $h && defined $m && defined $s or die "bad time for row: $row";

   return POSIX::mktime($s,$m,$h,$d,$mon-1,$y-1900);
}

############################################################################
# Main body
############################################################################
print "timestamp,buffer,query_tm,lock_tm,rows\n";

my $same_buff = 15;             # assume all rows within 15 secs of each other to be in same buffer if buffer_num <= 4
my ($buffer_num, $lastsecs) = (0, 0);
my ($firstrow, $addbuffer) = (1, 1);
$"=",";
while ( defined( my $row = <STDIN> ) ) {
   my @outcols = map { s/^.*=//r } split(" ", $row);
   if (@outcols != 5) {
      print STDERR "skipping invalid row: $row" if @outcols != 5;
      next;
   }

   if ($firstrow == 1) { 
      my @col_names = map { s/=.*$//r } split(" ", $row);
      if ("buffer" ~~ @col_names) {
         $addbuffer = 0;
      } else {
         $addbuffer = 1;
      }
      $firstrow = 0;
   }

   if ($addbuffer == 1) {
      my $esecs = get_epoch_from_iso( $outcols[0] );

      if ((abs($esecs - $lastsecs) <= 15) && $buffer_num < 4) {
	 ++$buffer_num;         # measure time delay from first row in group hence no lastsecs update here
      } else {
	 $buffer_num = 1;
	 $lastsecs = $esecs;
      }

      splice(@outcols, 1, 0, $buffer_num);
   }

   print "@outcols\n";
}
