#!/bin/bash

perl -lane 'BEGIN { print "timestamp,gf_fdcount,mysql_fdcount" } {($gfd,$mfd,$ts) = $_ =~ m/gf_fdcount=(\S+)\s+mysql_fdcount=(\S+)\s+(\S+)/; print "$ts,@{[($gfd =~ /^NO/)?0:$gfd]},@{[($mfd =~ /^NO/)?0:$mfd]}"}'
