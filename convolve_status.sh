#!/bin/bash
# $Id: convolve_status.sh 1.1 2019-07-22 05:19:48 cmayer $
#
# convolve_status.sh is a tool that interrogates the state of convolution 
# that may be running on a controller.
#
# for each of the tables that it knows about, it will report one of the following 3 lines:
#
# metricdata_min original 38 partitions
#
# 	this means that the table is not convolved and has the old primary key.  
# 	there are 38 partitions.
#
# metricdata_min_agg_app done old exists
#
# 	this means that the table is convolved and 
#	the old table still exists and may be dropped
#
# metricdata_ten_min working 38 of 38
#
# 	this means that the table is being convolved and is awaiting the rename step
#
# metricdata_ten_min_agg working 18 of 38
#
# 	this means that the table is being convolved and needs to be finished.
#	the process may not be running, in which it needs to be restarted.  
#	there probably needs to be a lock.
# metricdata_ten_min_agg_app done
#
#	this means that the table is convolved and there is nothing to do.
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

when run with no arguments, this program reports on the state of all convolvable
tables. if it has args, they are the list of tables to check on

examples:
	$0 -c /opt/AppDynamics/Controller metricdata_ten_min
what is the state of convolution for metricdata_ten_min for a controller installed
in /opt/AppDynamics/Controller

	$0 
what is the state of convolution on all metricdata tables for the
default controller install in $appd
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
# capture the tables to convolve
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
# return an index $2 in table $1
#
function if_index_exists() {
	local table=$1
	local index=$2

	sql "select distinct(index_name) \
		from information_schema.statistics \
		where table_name = \"$table\" and index_name = \"$index\""
}
	
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
# get create table statement for table $1
# this needs to be editable, so strip out silly comments
#
function get_create_table() {
	local table=$1

	sql "show create table $table\G" | 
		awk '/Create Table: / {$1 = "";$2 = "";t=1} {if (t == 1) {print}}' |
		sed -e 's,/\*!50100 ,,' -e 's,\*/,,'
}

#
# get the partitions of table $1 in a string suitable for an 'in' clause
#
function get_parts_as_in() {
	local table=$1

	sql "\
		set session group_concat_max_len = 30000; \
		select \
			concat(\"(\'\", \
				group_concat(distinct partition_name separator \"\',\'\"),\"\'\)\") \
		from information_schema.partitions \
		where table_name = \"$table\" \
	"
}

#
# get the partitions of table $1 as list
#
function get_partitions() {
	local table=$1

	sql " \
		select \
			distinct(partition_name) \
		from information_schema.partitions \
		where table_name = \"$table\" \
	"
}

#
# the stat command has different options
#
case `uname` in
Darwin)
	fmtflag=-f
	fmt_m=%m
	fmt_c=%c
	fmt_a=%a
	;;
Linux)
	fmtflag=-c
	fmt_m=%Y
	fmt_c=%Z
	fmt_a=%X
	;;
*)
	echo system `uname` unsupported
	exit
	;;
esac

#
# given a table $1 and partition $2, return a specific timestamp $3
# m - modified 
# c - changed
# a - accessed
#
function get_file_time() {
	local table=$1
	local part=$2
	local format=$3

	case $format in
	m)	fmt=$fmt_m
		;;
	c)	fmt=$fmt_c
		;;
	a)	fmt=$fmt_a
		;;
	esac

	filename="$table#P#${part}*.ibd"
	stat $fmtflag $fmt $datadir/controller/$filename | sort -n | tail -1
}

#
# get the row count from the partition table for table $1 part $2
#
function get_row_count() {
	local table=$1
	local part=$2

	sql "\
		select max(table_rows) \
		from information_schema.partitions \
		where table_name = \"$table\" and partition_name = \"$part\" \
	"
}

#
# get the limit value for table $1 part $2
#
function get_limit() {
	local table=$1
	local part=$2

	sql "\
		select distinct(partition_description) \
		from information_schema.partitions where \
		partition_name = \"$part\" and table_name = \"$table\" \
	"
}

#
# get the base value for a partition
#
function get_base() {
	local table=$1
	local part=$2
	sql "\
		select max(partition_description) \
		from information_schema.partitions where \
		partition_name < \"$part\" and table_name = \"$table\" \
	"
}

#
# construct the where clause for table $1 part $2
# return null string if partition no longer exists
#
function get_part_expression() {
	local table=$1
	local part=$2
	local base=`get_base $table $part`
	local limit=`get_limit $table $part`
	local partkey=`sql "select distinct(partition_expression) \
		from information_schema.partitions where table_name = \"$src\""`

	if [ -z "$limit" ] ; then
		echo ""
		return 
	fi

	if [ -z "$base" -o $base = "NULL" ] ; then 
		base=0
	fi
	if [ $part == PARTMAX ] ; then
		echo "$partkey >= $base"
	else
		echo "$partkey >= $base and $partkey < $limit"
	fi
	return
}

#
# get the last ts_min from table $1 constrained by partition expression $2
#
function get_last_ts_min() {
	local table=$1
	local expr=$2
	local query="select max(ts_min) from $table where $expr"

	value=`sql "$query"`
	if [ -z "$value" -o "$value" = "NULL" ] ; then
		value=0
	fi
	echo $value
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

#
# is partition $3 of table $1 and table $2 done
#
function partition_done() {
	local src=$1
	local dest=$2
	local part=$3

	local expr=`get_part_expression $src $part`

	if [ -z "$expr" ] ; then echo "$part no longer exists"
		return
	fi

	src_last_time=`get_last_ts_min $src "$expr"`
	dest_last_time=`get_last_ts_min $dest "$expr"`
	timediff=$((src_last_time - dest_last_time))
	# printf "%-11s %8d %8d %8d %s\n" $part $src_last_time $dest_last_time $timediff "$expr"
	if [ $src_last_time != $dest_last_time ] ; then
		return 1
	else
		return 0
	fi
}

function report() {
	local src=$1
	local dest=fast_$1
	local oldkey=`get_primary_key "$src"`
	local newkey="$2"
	local pcount=0
	local todo=0

	if table_exists $src && [ $oldkey = $newkey ] ; then
		src=old_$1
		dest=$1	
		if table_exists $src ; then
			echo $1 done old exists
		else
			echo $1 done
		fi
	elif table_exists $dest ; then
		partkey=`sql "select distinct(partition_expression) \
			from information_schema.partitions where table_name = \"$src\""`

		partitions=`get_partitions $src | sort -r`

		for part in $partitions ; do
			if partition_done $src $dest $part ; then
				((todo++))
			fi
			((pcount++))
		done
		echo $1 working $todo of $pcount
	else
		partitions=`get_partitions $src | sort -r`
		for part in $partitions ; do
			((pcount++))
		done	
		echo $1 original $pcount partitions
	fi
}

#
# actually do the work of convolving the metric tables
#
for table in $tables ; do
	if ! primary=`get_new_primary $table` ; then
		echo "$table unknown - skipping"
		continue
	fi
	report "$table" "$primary"
done

exit
