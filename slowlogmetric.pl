#!/usr/bin/env perl

# script to parse out secs taken by metricdata_min inserts from MySQL slow.log
# Works with older controller syntax and can be extended easily.
# Can work on arbitrarily large files as input is processed as it streams.
#								ran Aug-2016
# Updated to cope with Percona slow.log files.
#								ran Sep-2016
# Added CSV output support.
#								ran Oct-2016
# Fixed wrong output bug that surfaced when '# Time:' delimited block
# contained multiple select statements and only later ones matched
#								ran Jul-2018

use warnings;
use strict;

use POSIX qw( tzset mktime );
use Getopt::Long;

sub usage {
   return "Usage: $0 -tz <timezone_tz eg America/Los_Angeles> -th <secs to ignore> [-c]\n";
}

############################################################################
# Main body
############################################################################
my %args;
GetOptions(\%args, "tz=s", "th=s", "csv") or die usage();
exists $args{tz} || die usage();
my $thresh_secs = (exists $args{th})? $args{th} : 0;	# show all query times above 0

$ENV{TZ} = $args{tz};			# set script's timezone to given one
POSIX::tzset();

$/ = "# User\@Host: ";			# read in blocks delimited by this string

my $insert_cmd1 = qr{LOAD DATA CONCURRENT LOCAL INFILE .dummy.txt. IGNORE INTO TABLE metricdata_min FIELDS};	# 2012 syntax
my $insert_cmd2 = qr{.. .. LOAD DATA CONCURRENT LOCAL INFILE .dummy.txt. IGNORE INTO TABLE metricdata_min FIELDS}; # 2012 syntax
my $insert_cmd3 = qr{INSERT IGNORE INTO metricdata_min\s+SELECT};	# 4.2 syntax
my $insert_cmd = qr/(?:$insert_cmd1)|(?:$insert_cmd2)|(?:$insert_cmd3)/;

print "timestamp,avg_query_tm,avg_lock_tm,rows\n" if exists $args{csv};

while (defined (my $block = <STDIN>) ) {
   while ($block =~ m/# Query_time: (\S+)\s+Lock_time: (\S+).*?Rows_examined: (\d+).*?SET timestamp=(\d+);\s+${insert_cmd}/msgc) {
      my $query_tm = $1;
      my $lock_tm = $2; 
      my $rows_ex = $3;
      my $esecs = $4;

      my @struct_tm = localtime( $esecs );
      my $datetm = sprintf("%4d-%02d-%02dT%02d:%02d:%02d", $struct_tm[5]+1900, $struct_tm[4]+1, $struct_tm[3], 
							   $struct_tm[2], $struct_tm[1], $struct_tm[0]);

      if (exists $args{csv}) {
	 print "$datetm,$query_tm,$lock_tm,$rows_ex\n" if $query_tm > $thresh_secs;
      } else {
	 print "$datetm\tquery_tm=$query_tm\tlock_tm=$lock_tm\trows=$rows_ex\n" if $query_tm > $thresh_secs;
      }
   }
}
