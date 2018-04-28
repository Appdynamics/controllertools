#!/bin/bash
#
# $Id: hangcheck.sh 1.1 2018-04-28 14:23:28 cmayer
#
# this is intended to be a process that pings a local controller port
# if it times out often enough, generate a thread dump.
# don't thread dump too often
#
# let's find the controller
#
CONTROLLER_ROOT=$(ps -ef | \
	grep appserver/glassfish/domains/domain1/config | grep -v grep | \
	sed -e 's,.*-javaagent:,,' -e 's,/appserver/glassfish/domain.*,,')

LOGFILE=$CONTROLLER_ROOT/logs/hangcheck.log

PROTOCOL=http
PORT=8293

INTERVAL=15
FAILURES=3

URL=$PROTOCOL://localhost:$PORT/controller/rest/serverstatus
LASTDUMP=0
DUMPFREQ=$((30*60))
KEEP=5

DUMPDIR=$CONTROLLER_ROOT/appserver/glassfish/domains/domain1/config
losecount=0

DUMPCMD="$CONTROLLER_ROOT/appserver/glassfish/bin/asadmin --user=admin --passwordfile=$CONTROLLER_ROOT/.passwordfile \
	generate-jvm-report --type=thread"

while [ 1 ]; do
	NOW=$(date +%s)
	NEXT=`expr $NOW + $INTERVAL`

	#
	# ping our url
	#
	wget -O /dev/null --quiet --tries 1 -T 10 $URL
	ret=$?
	#
	# oh, no! we can't get in
	#
	if [ $ret -gt 0 ] ; then
		#
		# must be hung if we lost $FAILURES times..
		#
		if [ $((losecount++)) -gt $FAILURES ] ; then

			#	
			# we can't dump too often
			#
			if [ $(date +%s) -gt $((LASTDUMP + DUMPFREQ)) ] ; then
				echo thread dump
				pid=$(pgrep -f $CONTROLLER_ROOT/appserver/glassfish/domains/domain1/config)

				#
				# if there's already a dumpfile for this pid, save it.
				# let's keep the last $KEEP saved files
				# XX - this code will leak thread dumps if we restart a lot.
				#      there could be a lot of hotspot_pidxxxxx.log files
				#
				dumpfile=$DUMPDIR/thread_dump.log
				if [ -f $dumpfile ] ; then
					echo there is a dumpfile
					mv $dumpfile $DUMPDIR/thread_dump.$(stat -f %Sc $d | tr ' ' '-').log
					rm -f $(ls -1t $DUMPDIR/thread_dump.* 2>/dev/null | tail +$((KEEP+1)))
				fi
				$DUMPCMD >$dumpfile
				LASTDUMP=$(date +%s)
			else
				echo suppressed thread dump
			fi
			losecount=0
		fi
	fi

	NOW=$(date +%s)
	if [ $NEXT -gt $NOW ] ; then
		sleep $((NEXT - NOW))
	fi
done
