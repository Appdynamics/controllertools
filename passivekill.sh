#!/bin/bash
#
# $Id: passivekill.sh  2018-03-26 07:48:53 cmayer
#
# this is intended to be a cron job that runs frequently on each node
# if at any time, it returns 'passive' from the database, it is to
# kill any java appserver
#
CONTROLLER_ROOT=/opt/AppDynamics/Controller
LOGFILE=$CONTROLLER_ROOT/logs/passivekill.log

#
# read the database for the local controller mode
#
function getmode {
	echo "select value from global_configuration_local where name = 'appserver.mode'" | $CONTROLLER_ROOT/bin/controller.sh login-db 2>/dev/null
}

#
# if we get the string 'passive' back, kill any and all java processes
#
if getmode | grep -s -q passive ; then
	echo "---------------------" >> $LOGFILE
	date >> $LOGFILE
	echo "killing passive appserver" >> $LOGFILE
	getmode >> $LOGFILE
	pkill -9 -l java >> $LOGFILE
fi
