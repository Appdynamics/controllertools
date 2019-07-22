#!/bin/bash
# $Id: convolve_spacecheck 1.1 2019-07-22 05:19:48 cmayer $
#
# convolve_spacecheck.sh is a tool that asks the question if enough space is on the
# filesystem to convolve the table in the required argument.
#
# it returns messages, but mostly an exit code
# exit code meanings:
#
# 0: there is enough space to convolve
# 1: space is too small to convolve
# 2: the table is convolved, and you can drop the old table to free space
# 3: table is already convolved
# 4: there's a problem with the arguments or environment
#

appd=/opt/appdynamics/controller
alltables=()
errfile=errorfile
verbose=0
#
# the amount of expansion due to convolution we estimate.  it's conservative
#
fuzz=1.2

function usage() {
	cat << DOC
usage: $0 "[<args>] <tablename> "
	-c <appdynamics root dir>   controller install directory (default $appd)
DOC
}

while getopts "vc:" opt; do
	case $opt in
    	c)
		appd=$OPTARG
      		;;
	h)
		usage
		exit 4
		;;
    	\?)
		echo "Invalid option: -$OPTARG"
		usage
		exit 4
      		;;
  	esac
done

#
# capture the tables to convolve
#
((OPTIND--))
shift $OPTIND
table=$*

if [ -z $table ] ; then
	echo "must specify a table to check"
	usage
	exit 4
fi

#
# get connectivity to mysql - set a bunch of global variables
#
mysql=$appd/db/bin/mysql
if [ ! -x $mysql ] ; then
	echo "$mysql not executable"
	exit 4
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
		exit 4
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
	exit 4
fi

#
# extract the existing primary key for table $1
#
function get_primary_key() {
	local table=$1

	sql "\
		select \
			concat(\"\`\", \
			group_concat(column_name \
				order by ordinal_position separator \"\`,\`\"),\"\`\") \
		from information_schema.key_column_usage \
		where table_name = \"$table\" \
	"
}

#
# test if table $1 exists
#
function table_exists() {
	local table=$1
	local query="show tables like '$table'"

	sql "$query" | grep -s -q $table
}

#
# return the new primary key for table $1
#
function get_new_primary() {
	local table=$1

	case $table in
	metricdata_min)
		echo '`metric_id`,`node_id`,`ts_min`'
		return 0
		;;
	metricdata_min_agg)
		echo '`metric_id`,`application_component_instance_id`,`ts_min`'
		return 0
		;;
	metricdata_min_agg_app)
		# echo '`metric_id`,`application_id`,`ts_min`'
		echo '`metric_id`,`ts_min`'
		return 0
		;;
	metricdata_ten_min)
		echo '`metric_id`,`node_id`,`ts_min`'
		return 0
		;;
	metricdata_ten_min_agg)
		echo '`metric_id`,`application_component_instance_id`,`ts_min`'
		return 0
		;;
	metricdata_ten_min_agg_app)
		# echo '`metric_id`,`application_id`,`ts_min`'
		echo '`metric_id`,`ts_min`'
		return 0
		;;
	metricdata_hour)
		echo '`metric_id`,`node_id`,`ts_min`'
		return 0
		;;
	metricdata_hour_agg)
		echo '`metric_id`,`application_component_instance_id`,`ts_min`'
		return 0
		;;
	metricdata_hour_agg_app)
		# echo '`metric_id`,`application_id`,`ts_min`'
		echo '`metric_id`,`ts_min`'
		return 0
		;;
	*)
		return 1
	esac
}

if ! newkey=`get_new_primary $table` ; then
	echo "$table unknown"
	exit 4
fi

oldkey=`get_primary_key "$table"`

if [ $oldkey = $newkey ] ; then
	if table_exists old_$table ; then
		echo $1 done old exists
		exit 2
	else
		echo $1 done
		exit 3
	fi
fi

mbused=$(find $datadir/controller -name $table#P\* -printf "%k\n" | awk '{k+=$1}END{print int(k/1024)}')
mbfree=$(df -m --output=avail $datadir | tail -1)
mbneeded=$(awk "END{print int($mbused * $fuzz)}" </dev/null)

echo $table used: $mbused needed: $mbneeded free: $mbfree
if [ $mbneeded -lt $mbfree ] ; then
	echo space ok
	exit 0
else
	echo space short
	exit 1
fi

