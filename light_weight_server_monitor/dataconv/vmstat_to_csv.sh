#!/bin/bash

# Assumes input from "vmstat -t X" i.e. with timestamp on each row

tr -d '\r' | awk '
function checkdata() {
	if (NF>maxc) { 
		maxc=NF 
	}
	if (NF<minc) { 
		minc=NF 
	} 
	if (maxc != minc) { 
		print "ERROR: inconsistent column count (maxc="maxc",minc="minc") in row "NR > "/dev/stderr"
		exit 1
	}
}
BEGIN { print "timestamp,running,swpd,free,cache,si,so,bi,bo,in,cs,us,sy,id"; maxc=0; minc=9999999 }
$1 !~ /^[pr]/ { checkdata(); printf "%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", $18,$1,$3,$4,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15 }
'
