#!/usr/bin/env perl

#
# reformat output of iostat -tmx 60 to put (converted) datetime beside each (sd|nv|fi)* output line
# this simplifies fgrep correlation
#

use warnings;
use strict;
#use diagnostics;

use POSIX qw( mktime );
use Getopt::Long;

sub usage {
   return "Usage: $0 [-c] < <iostat_tzmx_60_output>\n";
}

sub reformat_to_iso {
   my $row = $_[0];
   defined $row or die "reformat: needs date string arg";

   my ($mon,$day,$year,$hr,$min,$sec,$ampm) = $row =~ m{(\d+)/(\d+)/(\d+)\s+(\d+):(\d+):(\d+)(?:\s+(AM|PM))*}i;
   if (defined $ampm) {
      $ampm = lc $ampm;
      die "reformat: invalid am/pm value '$ampm'" unless $ampm =~ m/^(am|pm)$/;

      # 12 AM == 00 hrs
      # 12 PM == 12 hrs
      # otherwise if pm then add 12
      if ($hr == 12) {
	 $hr = 0 if ($ampm eq 'am');
      } else {
	 $hr = ($ampm eq 'am')? $hr : 12+$hr;
      }
   }

   if ($year < 50) {		
      $year += 2000;
   } elsif ($year <= 99) {
      $year += 1900;
   }
   defined $day && defined $mon && defined $year or die "bad date for $row";

   #return sprintf("%04d-%02d-%02dT%02d:%02d:%02d", $year, $mon, $day, $hr, $min, $sec);
   return sprintf("%04d-%02d-%02dT%02d:%02d", $year, $mon, $day, $hr, $min);	# ignore sec so can join with rolled up slow.log
}

# accept a date & time string and then return epoch seconds for 00:00 of current day
# date is: MM/DD/YY[YY] eg 08/30/2016 or 08/30/16
sub get_epoch_to_midnight {
   my $datestr = $_[0] // die "get_epoch_to_midnight: needs date string";

   my ($mon,$d,$y) = $datestr =~ m{^(\d\d)/(\d\d)/(\d+)};
   if ($y < 50) {		
      $y += 2000;
   } elsif ($y <= 99) {
      $y += 1900;
   }
   defined $d && defined $mon && defined $y or die "bad date for $_[0]";

   return POSIX::mktime(0,0,0,$d,$mon-1,$y-1900);
}

# combine epoch secs to midnight and time into that day to make ISO datetime
# call as:
#  $str = mkdatetime( $secs_to_midnight, $in_time )
sub mkdatetime {
   my $secs_to_midnight = $_[0] // die "mkdatetime: needs epoch secs arg";
   my $in_time = $_[1] // die "mkdatetime: needs time arg";

   my ($hr,$min,$sec,$ampm) = $in_time =~ m{(\d\d):(\d\d):(\d\d)\s+(AM|PM)}i;
   $ampm = lc $ampm;
   die "reformat: invalid am/pm value '$ampm'" unless $ampm =~ m/^(am|pm)$/;

   # 12 AM == 00 hrs
   # 12 PM == 12 hrs
   # otherwise if pm then add 12
   if ($hr == 12) {
      $hr = 0 if ($ampm eq 'am');
   } else {
      $hr = ($ampm eq 'am')? $hr : 12+$hr;
   }

   my $secs_into_day = 3600*$hr + 60*$min + $sec;
   my @struct_tm = localtime( $secs_to_midnight + $secs_into_day );

   return sprintf("%4d-%02d-%02dT%02d:%02d", $struct_tm[5]+1900, $struct_tm[4]+1, 
   						$struct_tm[3], $struct_tm[2],
						$struct_tm[1]);
}

############################################################################
# Main body
############################################################################
my %args;
GetOptions(\%args, "c") or die usage();
my $cdel = (exists $args{c})? 1 : 0;

# iostat -t datetime outputs differ substantially :-(
# read first row and assume subsequent format...
my $row = <STDIN>;
my @col = split(" ", $row);
my $ncols = scalar @col;

if ($ncols == 7) {			# assume blocks headed by 'MM/DD/YY[YY] HH:MM:SS'
   $/ = "";				# terminate input on one or more contiguous empty lines
   my ($in_datetime,$cpu_head,$cpu_stats,$out_datetime,$device_head) = ("","","","","");
   my $first = 1;
   while (defined (my $block = <STDIN>)) {
      $block =~ s/\015?\012/\n/g;     	# normalise Windows CRLF to just LF
      next if $block =~ m/^Linux /;	# skip header row when concatenating multiple files - assume each file of same format !!

      if ($block =~ m{^\d+/\d}) { 	# date & CPU block found 
	 ($in_datetime,$cpu_head,$cpu_stats) = $block =~ m{(\d\d/\d\d/\d\d.*)\s+.*?(%user.*?idle)\s+(\d+.\d+.*?)$}m;
	 $out_datetime = reformat_to_iso( $in_datetime );
      } else {				# Device block found
         $block =~ s/^dm-.*\n//g;      	# drop all dm- device rows
	 ($device_head) = $block =~ m{^(Device.*?util)\s}mgc;

	 defined $device_head || die "Failed to parse Device details within: $block";
	 if ($first == 1) {
	    my $hdr = "timestamp\t\t$device_head\t$cpu_head";
	    $hdr = join(",", map { my $c = $_; $c =~ s/^\w+=//; $c } split(" ", $hdr)) if $cdel;
	    print "$hdr\n";
	    $first = 0;
	 }

	 while ($block =~ m/\G((?:sd|fi|nv).*)\s/mgc) {
	    my $device_stats = $1;
	    my $row = "$out_datetime\t$device_stats\t$cpu_stats";
	    $row = join(",", map { my $c = $_; $c =~ s/^\w+=//; $c } split(" ", $row)) if $cdel;
	    print "$row\n";
	 }

         $out_datetime = $cpu_stats = "";	# make it obvious if something goes wrong
      }
   }
} elsif ($ncols == 4) {			# assume blocks headed by 'Time: 07:36:02 PM'
   chomp( my $date = $col[-1]);
   my $secs_to_midnight = get_epoch_to_midnight( $date );
   $/ = "Time: ";                	# read in blocks delimited by this string
   my $first = 1;
   my $last_ampm;
   while (defined (my $block = <STDIN>) ) {
      $block =~ s/dm-.*\n//g;         	# drop all dm- device rows
      $block =~ s/\015?\012/\n/g;      	# normalise Windows CRLF to just LF
      pos $block = 0;

      while ($block =~ m{(\d\d:\d\d:\d\d.*)\s+.*?(%user.*?idle)\s+(\d+.\d+.*?)\s+(Device.*?util)\s+}mgc) {
	 my $in_time = $1;
	 my $cpu_head = $2; 
	 my $cpu_stats = $3;
	 my $device_head = $4;

	 my ($ampm) = $in_time =~ m/((?:am)|(?:pm))$/i;
	 defined $ampm or die "Missing AM/PM from time $in_time in block: $block";
	 $ampm = lc( $ampm );
	 
	 if (defined $last_ampm) {	# if not first time round
	    $secs_to_midnight += 86400 if $last_ampm ne $ampm;	# new day has appeared
	 }
	 my $out_datetime = mkdatetime( $secs_to_midnight, $in_time );
	 $last_ampm = $ampm;

	 if ($first eq 1) {
	    my $hdr = "\ttimestamp\t$device_head\t$cpu_head";
	    $hdr = join(",", map { my $c = $_; $c =~ s/^\w+=//; $c } split(" ", $hdr)) if $cdel;
#	    $hdr = join(",", map { $_ =~ s/^\w+=//r } split(" ", $hdr)) if $cdel;
	    print "$hdr\n";
	    $first = 0;
	 }

	 while ($block =~ m/\G((?:sd|fi|nv).*)\s/mgc) {
	    my $device_stats = $1;
	    my $row = "$out_datetime\t$device_stats\t$cpu_stats";
	    $row = join(",", map { my $c = $_; $c =~ s/^\w+=//; $c } split(" ", $row)) if $cdel;
#	    $row = join(",", map { $_ =~ s/^\w+=//r } split(" ", $row)) if $cdel;
	    print "$row\n";
	 }
      }
   }
}
