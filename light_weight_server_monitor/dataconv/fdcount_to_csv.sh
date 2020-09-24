#!/bin/bash

perl -lane 'BEGIN { 
	print "timestamp,gf_fdcount,mysql_fdcount";
	$minc=9999999;
	$maxc=0;
	sub check {
		my $nf = scalar @F;
		$maxc = $nf if $nf > $maxc;
		$minc = $nf if $nf < $minc;
		die "ERROR: inconsistent column count (maxc=$maxc,minc=$minc) in row $." if $maxc != $minc;
	}
	} 
	{
		check();
		($gfd,$mfd,$ts) = $_ =~ m/gf_fdcount=(\S+)\s+mysql_fdcount=(\S+)\s+(\S+)/; print "$ts,@{[($gfd =~ /^NO/)?0:$gfd]},@{[($mfd =~ /^NO/)?0:$mfd]}"
	}'
