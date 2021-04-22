#!/usr/bin/env perl

#
# rewrite of iostat to CSV to permit DOS or Linux/Unix delimited lines - using $/ to delimit readline does not work with files that might have DOS delimiters
#

use warnings;
use strict;

use POSIX qw( mktime );

sub usage {
	return "Usage: $0 < <iostat monX file>";
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
   return sprintf("%04d-%02d-%02dT%02d:%02d", $year, $mon, $day, $hr, $min);    # ignore sec so can join with rolled up slow.log
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

# iostat -t datetime outputs differ substantially :-(
# read first row and assume subsequent format...
my $row = <STDIN>;
$row =~ s/\015?\012/\n/g; 	# normalise Windows CRLF to just LF
my @col = split(" ", $row);
my $ncols = scalar @col;

my $header_todo = 1;
if ($ncols == 7) {					# assume blocks headed by 'MM/DD/YY[YY] HH:MM:SS'
	my ($cpu_head,$cpu_stats,$out_datetime,$device_head) = ("","","","");
	while ( defined( $row = <STDIN> ) ) {
		$row =~ s/\015?\012/\n/g;		# normalise Windows CRLF to just LF
		chomp( $row ); next if length($row) == 0;

		next if $row =~ m/^Linux/;		# skip iostat header row

		if ($row =~ m{^\d+/\d}){		# input and parse all contiguous rows up to empty row
			$out_datetime = reformat_to_iso( $row );
			while ( defined( $row  = <STDIN> ) ){
				$row =~ s/\015?\012/\n/g;		# normalise Windows CRLF to just LF
				chomp( $row ); last if length($row) == 0;

				$cpu_head = $1  if $row =~ m/^avg-cpu:\s+(%user.*?idle)/;
				$cpu_stats = $1 if $row =~ m/^\s+(\d+.\d+.*?)$/;
			}
			next;				# back to top loop
		}

		if ($row =~ m/^Device:/){		# input and parse all device rows up to empty row
			($device_head) = $row =~ m/^(Device.*?util)$/;
			defined $device_head || die "Failed to parse Device details within: $row";
			if ($header_todo == 1) {
				my $hdr = join(",", map { my $c = $_; $c =~ s/^\w+=//; $c } split(" ", "timestamp\t\t$device_head\t$cpu_head"));
				print "$hdr\n";
				$header_todo = 0;
			}
			while ( defined( $row = <STDIN> ) ) {
				$row =~ s/\015?\012/\n/g;			# normalise Windows CRLF to just LF
				chomp( $row ); last if length($row) == 0;

				next if $row =~ m/^dm-/;			# drop all dm-* device stats - raw block devices simpler
				next unless $row =~ m/^(?:sd|fi|nv|xv|em)/;	# only report devices with these prefixes
				check(scalar split(" ", $row), $row);
				my $orow = join(",", map { my $c = $_; $c =~ s/^\w+=//; $c } split(" ", "$out_datetime\t$row\t$cpu_stats"));
				print "$orow\n";
			}
			next;				# back to top loop
		}
	}
} elsif ($ncols == 4) {					# assume blocks headed by 'Time: 07:36:02 PM'
	# currently short of time and old iostat examples.... will leave this unimplemented for now
	die "older iostat format found... CSV parsing needs implementing for this!";

	chomp( my $date = $col[-1]);
	my $secs_to_midnight = get_epoch_to_midnight( $date );
	my $last_ampm;
	while ( defined( $row = <STDIN> ) ) {
		$row =~ s/\015?\012/\n/g;		# normalise Windows CRLF to just LF
	}
}