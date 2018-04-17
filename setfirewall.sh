#!/bin/bash
#
# $Id: setfirewall.sh 1.1 2018-03-27 17:14:20 cmayer
#
# this is intended to be a cron job that runs frequently on each node
# if at any time, it returns 'passive' from the database,
# firewall out the incoming traffic
#
#
# there are a fair number of settings in here that are dynamically determined
# it is better to hard code them, though, since this thing runs A LOT.
#
# this needs to be set to the EC host
EC_HOST=
EC_IP=$(ping -q -c 1 -t 1 $EC_HOST | grep PING | sed -e "s/).*//" | sed -e "s/.*(//")

#
# port to block, 8181 or 8090...  if we need to block both, we need to clone the rule..
#
PORT=8181

CONTROLLER_ROOT=/opt/AppDynamics/Controller
LOGFILE=$CONTROLLER_ROOT/logs/passivekill.log

user=$(grep user= $CONTROLLER_ROOT/db/db.cnf | awk -F = '{print $2}')

#
# read the database for the local controller mode
#
function getmode {
	echo "select value from global_configuration_local where name = 'appserver.mode'" | su $user -s $CONTROLLER_ROOT/bin/controller.sh login-db 2>/dev/null
}

#
# if we get the string 'passive' back, block port to everyone except EC
#
if getmode | grep -s -q active ; then
	/sbin/iptables -D INPUT -p tcp ! -s $EC_IP --dport $PORT -j DROP > /dev/null 2>&1
else
	/sbin/iptables -A INPUT -p tcp ! -s $EC_IP --dport $PORT -j DROP
fi
