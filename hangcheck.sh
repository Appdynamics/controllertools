#!/bin/bash
#
# $Id: hangcheck.sh 1.2 2018-04-28 14:42:23 cmayer
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

#
# ping this port
#
PROTOCOL=http
PORT=8293
URL=$PROTOCOL://localhost:$PORT/controller/rest/serverstatus

#
# every $INTERVAL seconds
#
INTERVAL=15

#
# $FAILURES in a row causes dump
#
FAILURES=3

#
# we only make 1 dump every $DUMPFREQ seconds
#
DUMPFREQ=$((30*60))

#
# keep $KEEP logs around; toss the rest
#
KEEP=5

#
# where to put the thread dumps
#
DUMPDIR=$CONTROLLER_ROOT/logs

#
# not strictly the last dump - the last dump from this process
#
lastdump=0

#
# how many times our ping failed this iteration
#
losecount=0

#
# cleaner than using a signal, since we can put the output where we want it
#
DUMPCMD="$CONTROLLER_ROOT/appserver/glassfish/bin/asadmin --user=admin --passwordfile=$CONTROLLER_ROOT/.passwordfile \
	generate-jvm-report --type=thread"

while true ; do
	NOW=$(date +%s)
	NEXT=$((NOW + INTERVAL))

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
			if [ $(date +%s) -gt $((lastdump + DUMPFREQ)) ] ; then
				pid=$(pgrep -f $CONTROLLER_ROOT/appserver/glassfish/domains/domain1/config)

				#
				# if there's already a dumpfile for this pid, save it.
				# let's keep the last $KEEP saved files
				#
				dumpfile=$DUMPDIR/thread_dump.log
				if [ -f $dumpfile ] ; then
					mv $dumpfile $DUMPDIR/thread_dump.$(stat -f %Sc $d | tr ' ' '-').log
					rm -f $(ls -1t $DUMPDIR/thread_dump.* 2>/dev/null | tail +$((KEEP+1)))
				fi
				$DUMPCMD >$dumpfile
				lastdump=$(date +%s)
			fi
			losecount=0
		fi
	else
		losecount=0
	fi

	NOW=$(date +%s)
	if [ $NEXT -gt $NOW ] ; then
		sleep $((NEXT - NOW))
	fi
done
