#!/bin/bash
# $Id: convolve_reclaim.sh 1.2 2019-07-30 12:22:37 cm68 $
#
# convolve_reclaim.sh is a tool that reaps the old tables
#

appd=/opt/appdynamics/controller
alltables=()
errfile=errorfile
verbose=0

#
# build list of all convolvable tables
#
for time_dim in min ten_min hour ; do
	for rollup_dim in "" _agg _agg_app ; do
		alltables+=(metricdata_$time_dim$rollup_dim)
	done
done

function usage() {
	cat << DOC
usage: $0 "[<args>] [<tablename> ...] "
	-c <appdynamics root dir>   controller install directory (default $appd)
	-v verbose

	when run with no arguments, it reaps the space for the pre-convolved
	tables
examples:
	$0 -c /opt/AppDynamics/Controller metricdata_ten_min
	remove old_metricdata_ten_min

	$0 
	remove all old metricdata tables
DOC
}

while getopts "vc:" opt; do
	case $opt in
    	c)
		appd=$OPTARG
      		;;
	v)
		((verbose++))
		;;
	h)
		usage
		exit
		;;
    	\?)
		echo "Invalid option: -$OPTARG"
		usage
		exit
      		;;
  	esac
done

#
# capture the tables to remove
#
((OPTIND--))
shift $OPTIND
tables="$*"

if [ -z "$tables" ] ; then
	tables="${alltables[@]}"
fi

#
# get connectivity to mysql - set a bunch of global variables
#
mysql=$appd/db/bin/mysql
if [ ! -x $mysql ] ; then
	echo "$mysql not executable"
	exit
fi

datadir=`grep ^datadir $appd/db/db.cnf | awk -F= '{print $2}'`

mysql_port=`grep ^DB_PORT $appd/bin/controller.sh | awk -F= '{print $2}'`
if [ -z "$mysql_port" ] ; then
	mysql_port=3388
fi

mysql_password=`grep ^mysql_root_user_password $appd/bin/controller.sh | 
	awk -F= '{print $2}'`
if [ -z "$mysql_password" ] ; then
	if [ -f $appd/db/.rootpw ] ; then
		mysql_password=`cat $appd/db/.rootpw`
	else
		echo "this tool requires a readable db/.rootpw"
		exit 1
	fi
fi

connect="--user=root --host=localhost --port=$mysql_port --protocol=TCP"
if $mysql --version | fgrep -q -s 5.7 ; then
	export MYSQL_PWD="$mysql_password"
else
	connect="$connect --password=$mysql_password"
fi

#
# execute a sql statement in $1 and send the output to stdout
#
function sql() {
	echo "$1" | $mysql $connect --silent controller 2>>/dev/null
}

#
# let's do a trivial check for sql connectivity
#
if ! sql "show databases" | grep -q controller ; then
	echo "mysql connection using $mysql $connect failed"
	exit 1
fi

#
# test if table $1 exists
#
function table_exists() {
	local table=$1
	local query="show tables like '$table'"

	sql "$query" | grep -s -q $table
}

#
# actually do the work of convolving the metric tables
#
for table in $tables ; do
	if table_exists old_$table ; then
		if [ $verbose ] ; then
			echo "drop table old_$table"
		fi
		sql "drop table old_$table"
	fi
done

exit
