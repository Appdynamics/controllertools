#!/usr/bin/env perl

#
# rewrite of iostat to CSV to permit DOS or Linux/Unix delimited lines - using $/ to delimit readline does not work with files that might have DOS delimiters
#

use warnings;
use strict;

use POSIX qw( mktime );

# US/UK
my %nmon = ( 'January'=>'01', 'February'=>'02', 'March'=>'03', 'April'=>'04', 'May'=>'05', 'June'=>'06', 
	'July'=>'07', 'August'=>'08', 'September'=>'09', 'October'=>'10', 'November'=>'11', 'December'=>'12' );

sub usage {
	return "Usage: $0 < <iostat monX file>";
}

# convert to ISO dates like 'MM/DD/YY[YY] HH:MM:SS [AM|PM]' i.e. %m/%d/[%C]%y %T [%p]
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
   	defined $day && defined $mon && defined $year or die "@{[(caller(0))[3]]}: bad date for $row";

   	return sprintf("%04d-%02d-%02dT%02d:%02d:%02d", $year, $mon, $day, $hr, $min, $sec);
   	#return sprintf("%04d-%02d-%02dT%02d:%02d", $year, $mon, $day, $hr, $min);    # ignore sec so can join with rolled up slow.log
}

# convert to ISO a row like 'Tuesday 06 April 2021 12:17:01  IST'
sub date_to_iso {
	my $row = $_[0] // die "@{[(caller(0))[3]]}: needs a date string arg";
	my $mon;

	my ($day,$month,$year,$hr,$min,$sec) = $row =~ m/^\S+\s+(\d+)\s+(\S+)\s+(\d+)\s+(\d+):(\d+):(\d+)/;

	$mon = $nmon{$month};

   	if ($year < 50) {
      		$year += 2000;
   	} elsif ($year <= 99) {
      		$year += 1900;
   	}
   	defined $day && defined $mon && defined $year or die "@{[(caller(0))[3]]}: bad date for $row";

	return sprintf("%04d-%02d-%02dT%02d:%02d:%02d", $year, $mon, $day, $hr, $min, $sec);
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

# convert to ISO a row like '2021-04-21T20:41:49-0700' i.e. basically lose the TZ part and check all OK in the process
sub iso_withTZ_to_iso {
	my $row = $_[0] // die "@{[(caller(0))[3]]}: needs a date string arg";

	my ($year,$mon,$day,$hr,$min,$sec) = $row =~ m/^(\d\d\d\d)-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/;
	defined $day && defined $mon && defined $year or die "@{[(caller(0))[3]]}: bad date for $row";

	return sprintf("%04d-%02d-%02dT%02d:%02d:%02d", $year, $mon, $day, $hr, $min, $sec);
}

sub set_datetime_parser {
	my $row = $_[0] // die "@{[(caller(0))[3]]}: needs row arg";
	my $ref;

	my ($date) = $row =~ m/^\S+\s+\S+\s+\S+\s+(.*?)\s+_x86_.*?CPU.$/;	# snag the middle date part of header row

	my $ncols = scalar split(" ", $row);
	if ($ncols == 7) {
		if (($date =~ tr!/!!) == 2) {
			$ref = \&reformat_to_iso;		# assume dates like 'MM/DD/YY[YY] HH:MM:SS [AM|PM]' i.e. %m/%d/[%C]%y %T [%p]
		} elsif (($date =~ tr!-!!) == 2) {
			$ref = \&iso_withTZ_to_iso;		# assume dates like '2021-04-21T22:42:07[-0700]'
		} else {
			die "unable to parse iostat header: $row";
		}
	} elsif ($ncols == 10) {				# assume dates like 'Tuesday 06 April 2021 12:17:01  IST' i.e. %A %d %B %Y %T  %Z
		$ref = \&date_to_iso;
	} else {						# not yet implemented
		die "unable to parse iostat data - likely because date format parser unimplemented!";
	}

	return $ref;
}

############################################################################
# Main body
############################################################################

# iostat -t datetime outputs differ substantially :-(
# read first row and assume subsequent format...
my $row = <STDIN>;
$row =~ s/\015?\012/\n/g; 	# normalise Windows CRLF to just LF

# determine correct date parser from columns of header row 
my $read_datetime = set_datetime_parser( $row );	# set function pointer

my $header_todo = 1;
my ($cpu_head,$cpu_stats,$out_datetime,$device_head) = ("","","","");
while ( defined( $row = <STDIN> ) ) {
	$row =~ s/\015?\012/\n/g;		# normalise Windows CRLF to just LF
	chomp( $row ); next if length($row) == 0;

	if ($row =~ m/^Linux/) {			# set datetime parser and skip iostat header row - found with concatenated inputs
		$read_datetime = set_datetime_parser( $row );
		next;
	}

	if ($row =~ m{^\d+/\d} || ($row =~ tr/://) == 2){	# found datetime so input and parse all contiguous rows up to empty row
		$out_datetime = $read_datetime->( $row );
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
