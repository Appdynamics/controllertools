#!/usr/bin/env perl

# convert CSV to TSDB import format. 
# can process concatenated CSV files of different col numbers - assuming each begins with a header
# ASSUMES: 
# 1. row containing "timestamp," or ",timestamp" is header
# 2. timestamp precedes other columns (as it is common to all other columns)
# 3. buffer precedes other non-timestamp columns (as it is an attribute of others)

# Call as:
#  perl iostat_reformat.pl -c < <(cat *iostat*.txt) | perl scripts/csv_to_tsdb.pl -tz America/Los_Angeles -h <SERVERNAME> -m test1.1m.avg | nc -w 15 localhost 4242
# OR
#  bash scripts/join_iostat_slowlog.sh -t America/Los_Angeles -i /Users/rob.navarro/cstools/loganalyzer/zendesk/69501/August-15-2016_05.01.44/iostat_69501.txt/iostat_69501.txt -s /Users/rob.navarro/cstools/loganalyzer/zendesk/69501/August-15-2016_05.01.44/Controller_slow_auspappdynapm02.us.dell.com_logs_.log/Controller_slow_auspappdynapm02.us.dell.com_logs_.log -c | perl scripts/csv_to_tsdb.pl -tz America/Los_Angeles -m iostat_slowlog.1m.avg | nc -w 30 localhost 4242

# pre-pend 'put' for pipes to TSDB, else drop 'put' for import

use strict;
use warnings;

use Getopt::Long;
use POSIX qw( tzset mktime );

# parse epoch from string such as:
# 2015-01-19T16:23 ...
sub get_epoch_from_iso_min {
   my $row = $_[0];
   defined $row or die "get_epoch_from_iso_min: needs string arg";

   my ($ldate) = $row =~ m/^(\d{4,4}-\d{2,2}-\d{2,2}T\d{2,2}:\d{2,2})/gc;
   defined $ldate or die "busted date for row: $row";
   my ($y,$mon,$d,$h,$m,$s) = $ldate =~ m/(\d{4,4})-(\d{2,2})-(\d{2,2})T(\d{2,2}):(\d{2,2})/;
   defined $d && defined $mon && defined $y or die "bad date for row: $row";
   defined $h && defined $m or die "bad time for row: $row";
   if ($row =~ m/\G:(\d{2,2})/) {		# grab secs if exist
      $s = $1;
   } else {
      $s = 0;
   }

   return POSIX::mktime($s,$m,$h,$d,$mon-1,$y-1900);
}

sub usage {
   return "Usage: $0 
   	-tz <timezone_tz_eg_America/Los_Angeles>        # timezone name
	-m <tsdb metricname>
	[-h <hostname>]\n";
}

############################################################################
# Main body
############################################################################
my %args;
GetOptions(\%args, "tz=s", "metric=s", "host=s", "Loadid=s") or die usage();
exists $args{tz} && exists $args{metric} || die usage();

$ENV{TZ} = $args{tz};
POSIX::tzset();

my $tsdbmetric = $args{metric};
my $hoststr = "";
$hoststr = "host=$args{host}" if exists $args{host};
my $loadid = "";
$loadid = "loadid=$args{Loadid}" if exists $args{Loadid};

my $row_count = 0;
my @col_header;
while (defined (my $row = <STDIN>) ) {
   chomp( $row );

   if ($row =~ m/(?:timestamp,)|(?:,timestamp)/i) {		# assume that this row is a header and possibly start of new sequence of rows
      @col_header = map { my $c = $_; $c =~ s/\%/pct/; $c =~ tr/(/_/; $c =~ tr/)//d; $c } split(/,/, $row);
      next;
   }

   my @col = split(/,/, $row);

   my %row;
   @row{ @col_header } = @col;		# simplify value lookup

   my $epoch = 0;
   my $device = '';
   my $buffer = '';
   my $port = '';
   my $listener = '';
   my $node = '';
   my $zone = '';
   my $event = '';
   my $connuser = '';
   my $connhost = '';
   my %metric_cols;
   @metric_cols{ @col_header } = ();	# initialise with all names
   for my $col ( @col_header ) {	# get constant tags
      if ($col =~ m/^timestamp$/i) {
         $epoch = get_epoch_from_iso_min( $row{ $col } );
	 delete $metric_cols{ $col };
	 next;
      }
      if ($col =~ m/^buffer/i) {
	 $buffer = " buffer=$row{ $col }";
	 delete $metric_cols{ $col };
         next;
      }

      if ($col =~ m/^device/i) {
	 $device = " device=$row{ $col }";
	 delete $metric_cols{ $col };
         next;
      }
      
      if ($col =~ m/^port/i) {
	 $port = " port=$row{ $col }";
	 delete $metric_cols{ $col };
         next;
      }

      if ($col =~ m/^(listener|pool)$/i) {	# assuming listener & pool never used in same input CSV row
	 $listener = " $1=$row{ $col }";
	 delete $metric_cols{ $col };
         next;
      }

      if ($col =~ m/^node/i) {
	 $node = " node=$row{ $col }";
	 delete $metric_cols{ $col };
         next;
      }

      if ($col =~ m/^zone/i) {
	 $zone = " zone=$row{ $col }";
	 delete $metric_cols{ $col };
         next;
      }

      if ($col =~ m/^EVENT_NAME/i) {
	 $event = " event=$row{ $col }";
	 delete $metric_cols{ $col };
         next;
      }

      if ($col =~ m/^user$/i) {
	 $connuser = " connuser=$row{ $col }";
	 delete $metric_cols{ $col };
         next;
      }

      if ($col =~ m/^host$/i) {
	 $connhost = " connhost=$row{ $col }";
	 delete $metric_cols{ $col };
         next;
      }
   }
      
   for my $col ( keys %metric_cols ) {	# print out metrics only
      # throttle outputs to avoid OpenTSDB 'put: Please throttle writes: 10000 RPCs waiting on ' messages
      sleep 0.1 if $row_count % 150000 == 0;
      print "put $tsdbmetric $epoch $row{ $col } col=$col$device$buffer$port$listener$node$zone$event$connuser$connhost $hoststr $loadid\n" if length($row{ $col });
      ++$row_count;
   }
}
