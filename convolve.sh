#!/bin/bash
#
# re-layout the controller data tables for a different primary key ordering
# do this online to the maximum extent possible.
#
# space management runs on the controller at a variable frequency 
# by table interval on a fixed schedule. see next_space_management
#
# $Id: convolve.sh 3.0 2019-07-09 11:59:15 saradhip $

appd=/opt/appdynamics/controller
errfile=/tmp/convolve.err
new_tables=false
rename=false
report=false
truncate=false
parallel=1
verbose=0
procsleep=1
avoid=1
hiwatermark=0
alltables=()
use_alltables=false
use_saas=false

lockdir=/tmp

echo -n 'start convolving at ';
echo `date +%d/%m/%Y\ %H:%M:%S`;

#
# build list of all convolvable tables
#
for time_dim in min ten_min hour ; do
	for rollup_dim in "" _agg _agg_app ; do
		alltables+=(metricdata_$time_dim$rollup_dim)
	done
done

declare -a workers

function usage() {
	cat << DOC
usage: $0 "[<args>] <tablename> ... "
	-S saas assumptions
	-c <appdynamics root dir>   controller install directory (default $appd)
	-v verbose
	-R report
	-T tty output error
	-n create new tables
	-r rename tables
	-a <seconds> space management safety interval (default $avoid) 0 for disable
	-t truncate tables before convolve
	-P <n> parallelism (default $parallel)
	-A all tables (${alltables[@]})

when run with no arguments, this program creates metric tables named fast_\*
that have the primary key modified to put ts_min last.
additionally, a new secondary index, ts_min_index is created as a copy of the
original primary key

this program will pause the metric copies when coming too close to space management
in time. an informative message is printed. this function can be disabled by using -a 0

once it has been run completely without issue, it should be run with -r to
place the tables into production.  the original tables are renamed as old_\*

finally, after -r, a run of will back-copy any rows that were missed during the
switchover.

examples:
	$0 -c /opt/AppDynamics/Controller -P 6 metricdata_ten_min
will convolve metricdata_ten_min, 6 partitions at a time, 
into fast_metricdata_ten_min, which will be added to if it exists,

	$0 -r metricdata_ten_min
will rename metricdata_ten_min as old_metricdata_ten_min,
rename fast_metricdata_ten_min as metricdata_ten_min,
and insert any rows into metricdata_ten_min from old that were not
already there.

	$0 -n -t -r metricdata_ten_min
will truncate metricdata_ten_min, create fast_metricdata_ten_min,
rename fast_metricdata_ten_min as metricdata_ten_min,
rename metricdata_ten_min to old_metricdata_ten_min,
copy all rows from old_metricdata_ten_min to metricdata_ten_min
DOC
}

while getopts "SAhTRvnfrta:c:P:" opt; do
	case $opt in
		S)
			use_saas=true
			;;
		A)
			use_alltables=true
			;;
		a)
			avoid=$OPTARG
			;;
    	P)
			parallel=$OPTARG
      		;;
    	c)
			appd=$OPTARG
      		;;
		T)
			errfile=/dev/tty
			;;
    	R)
			report=true
      		;;
		v)
			((verbose++))
			;;
		n)
			new_tables=true
			;;
		t)
			truncate=true
			;;
		r)
			rename=true
			;;
		h)
			usage
			exit 1
			;;
    	\?)
			echo "Invalid option: -$OPTARG"
			usage
			exit 2
      		;;
  	esac
done

#
# capture the tables to convolve
#
((OPTIND--))
shift $OPTIND
tables="$*"
if $use_alltables ; then
	tables="${alltables[@]}"
fi

if [ -z "$tables" ] ; then
	echo no tables specified
	usage
	exit 1
fi

#
# get conectivity to mysql - set a bunch of global variables
#
if $use_saas ; then
	mysql=/usr/bin/mysql
	datadir=`grep -w datadir /etc/my.cnf | awk -F= '{print $2}'`
	mysql_port=`grep -w port /etc/my.cnf | awk -F= '{print $2}'`
	connect=
else
	mysql=$appd/db/bin/mysql
	mysql_password=`grep ^mysql_root_user_password $appd/bin/controller.sh | 
		awk -F= '{print $2}'`
	datadir=`grep ^datadir $appd/db/db.cnf | awk -F= '{print $2}'`
	mysql_port=`grep ^DB_PORT $appd/bin/controller.sh | awk -F= '{print $2}'`

	if [ -z "$mysql_password" ] ; then
		if [ -f $appd/db/.rootpw ] ; then
			mysql_password=`cat $appd/db/.rootpw`
		else
				echo "this tool requires a readable db/.rootpw"
				exit 3
		fi
	fi
	
	if [ -z "$mysql_port" ] ; then
		mysql_port=3388
	fi
# To suppress this message ion MySQL 5.7 --[Warning] Using a password on the command line interface can be insecure.
	export MYSQL_PWD="$mysql_password"
	connect="--user=root --port=$mysql_port --protocol=TCP"
#	connect="--user=root --password=$mysql_password --port=$mysql_port --protocol=TCP"

fi

if [ ! -x $mysql ] ; then
	echo "$mysql not executable"
	exit 4
fi

if [ ! -c $errfile ] ; then
	rm -f $errfile
	touch $errfile
fi

#
# notice that process ran for $1 seconds
#
function notice_time() {
	duration=$1

	if [ $hiwatermark = 0 ] ; then
		return
	fi
	if [ $duration -gt $hiwatermark ] ; then
		hiwatermark=$duration
		echo "hi water mark $hiwatermark seconds"
	fi
}

#
# check process pid $1 if it is still running
#
function check_process() {
	local pid=$1

	if [ $verbose -gt 2 ] ; then echo -n "check_process $pid" ; fi
	if kill -0 $pid 2>/dev/null ; then
		if [ $verbose -gt 2 ] ; then echo "yes" ; fi
		return 0
	else
		if [ $verbose -gt 2 ] ; then echo "no" ; fi
		return 1
	fi
}

#
# fix up the worker list
#
function reap_workers() {
	local pid
	local now=`date +%s`

	for pid in ${!workers[*]} ; do 
		if ! check_process $pid ; then
			start=${workers[pid]}
			duration=$((now - start))
			notice_time $duration
			unset workers[pid]
		fi
	done
	if [ $verbose -gt 2 ] ; then echo "reap before: $workers after: $copy" ; fi
}

#
# wait for all the workers to complete
#
function process_drain() {
	while [ ! -z "${workers[*]}" ] ; do
		reap_workers
		sleep $procsleep
	done
}

#
# wait for the process queue to drain to the point where we can start another worker
#
function wait_for_slot() {
	local running

	if [ $verbose -gt 2 ] ; then echo "wait for slot" ; fi
	while true ; do
		reap_workers
		running=`echo "${!workers[*]}" | wc -w`
		if [ $running -lt $parallel ] ; then
			break
		fi
		if [ $verbose -gt 2 ] ; then echo "no slots - sleeping" ; fi
		sleep $procsleep
	done
}

#
# add the process $1 to the worker list
#
function add_pid() {
	local pid=$1

	workers[pid]=`date +%s`
	unset workers[0]
}

#
# execute a sql statement in $2 for table $1 and send the output to stdout
# return false if we had to sleep for space management, don't bother to run
# query in this case
#
function schedule_sql() {
	local table=$1

	wait_for_slot
	if ! space_management_sleep $table ; then
		if [ $verbose -gt 1 ] ; then echo "schedule_sql: slept" ; fi
		return 1
	fi

	sql "$2" &
	background_pid=$!
	add_pid $background_pid
	return 0
}

#
# execute a sql statement in $1 and send the output to stdout
#
function sql() {
	if [ $verbose -gt 1 ] ; then echo "$1" >>$errfile ; fi
	echo "$1" | $mysql $connect --silent controller 2>>$errfile
}

#
# are we the active node?
#
function assert_active() {
	if sql "select value \
		from global_configuration_local \
		where name = \"appserver.mode\"" | grep -q -s active ; then
		return 0
	else
		echo "convolve aborted - not active"
		exit 9
	fi
}

#
# are we below 20GB of space
#
function assert_space() {
	local space=$(df -m --output=avail $datadir | tail -1)
	if [ $space -lt 20000 ] ; then
		echo "convolve aborted - disk space $space too low"
		exit 10
	fi
}

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
	exit 5
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
# return the time of the last space management run
#
function next_space_management()
{
	local table=$1

	#
	# saas machines run space management at specific times:
	# minute: every 30 minutes, on minute 2
	# ten minute: every 120 minutes, on minute 13
	# hour:  every 1440 minutes, on minute 43
	#
	case $table in
	metricdata_min*)
		modulus=30
		residue=2
		;;
	metricdata_ten_min*)
		modulus=120
		residue=13
		;;
	metricdata_hour*)
		modulus=1440
		residue=43
		;;
	*)
		echo "table $table not recognized"
		exit 6
		;;
	esac
	# seconds
	residue=$(($residue * 60))
	interval=$(($modulus * 60))

	when=`date -u +"((((%s+($interval-$residue))/$interval)*$interval)+$residue)-%s" | bc`
	next=`date +"%s + $when" | bc`
#	echo "table $table interval $interval residue $residue when $when next $next" 1>&2
	# don't use this code
	if false ; then
		last_1=`get_file_time $table PARTMAX c`
		last_2=`get_file_time ${table}_agg PARTMAX c`
		last_3=`get_file_time ${table}_agg_app PARTMAX c`

		last=$last_1
		if [ $last_2 -gt $hi ] ; then
			last=$last_1
		fi
		if [ $last_3 -gt $hi ] ; then
			last=$last_3
		fi
		next=$(($last + $interval))
	fi
	echo $next
}

#
# given a table $1, pause until the space management is done if it is too soon
#
space_management_sleep()
{
	local table=$1
	local now=`date +%s`
	local window=300

	if [ $hiwatermark = 0 ] ; then
		return 0
	fi

	when=`next_space_management $table`
	next=$(($when - $now))

	# if the next space management is in the past,
	# the controller must not be running, so no need to wait
	if [ $next -lt 0 ] ; then
	if [ $verbose -gt 0 ] ; then echo "space management not running" ; fi
		return 0
	fi

	# if the next space management is coming up within the expected runtime
	# of doing this partition, let's wait until the space management has run.
	#
	if [ $next -ge $hiwatermark ] ; then
	if [ $verbose -gt 0 ] ; then echo "space management in $next" ; fi
		return 0
	fi

	if [ $verbose -gt 0 ] ; then echo "space management sleep $next" ; fi
	sleep $(($next + $window))

	return 1
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
# copy table $1 into table $2 part $3
# return false if we should restart at partition list
#
function partition_copy() {
	local src=$1
	local dest=$2
	local part=$3

	if [ $verbose -gt 0 ] ; then echo -n "partition_copy $src $dest $part " ; fi

	# ignore partmax
	if [ $part == PARTMAX ] ; then
		if [ $verbose -gt 0 ] ; then echo "prune partmax" ; fi
		return 0
	fi

	# if no data in source partition, done
	srcrows=`get_row_count $src $part`
	if [ $srcrows -eq 0 ] ; then
		if [ $verbose -gt 0 ] ; then echo "prune src rows zero" ; fi
		return 0
	fi

	local srcexpr=`get_part_expression $src $part`
	if [ -z "$srcexpr" ] ; then
		if [ $verbose -gt 0 ] ; then echo "src partition gone" ; fi
		return 0
	fi

	local destexpr=`get_part_expression $dest $part`
	if [ -z "$destexpr" ] ; then
		if [ $verbose -gt 0 ] ; then echo "dest partition gone" ; fi
		return 0
	fi

	if [ "$dest_expr" != "$src_expr" ] ; then
		echo "source and dest expression mismatch"
		echo "src: $src $part $srcexpr"
		echo "dest: dest $part $destexpr"
		exit 7
	fi

	src_last_time=`get_last_ts_min $src "$srcexpr"`
	dest_last_time=`get_last_ts_min $dest "$srcexpr"`

	if [ $src_last_time -le $dest_last_time ] ; then
		if [ $verbose -gt 0 ] ; then echo "prune src older" ; fi
		return 0
	fi
	if [ $verbose -gt 0 ] ; then echo "insert new rows" ; fi
	
	avoidtable=$dest
	if [[ $dest == fast* ]] ; then
		avoidtable=$src
	fi
	order="order by `get_primary_key $dest`"

	schedule_sql $avoidtable "insert ignore into $dest select * from $src where $srcexpr $order"
}

#
# report on partitions part $3 of table $1 and table $2
#
function partition_report() {
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
	printf "%-11s %8d %8d %8d %s\n" $part $src_last_time $dest_last_time $timediff "$expr"
}

#
# iterate over the partitions of table $1 and table $2
#
function partition_iterate() {
	local src=$1
	local dest=$2

	#
	# get the partition key
	#
	partkey=`sql "select distinct(partition_expression) \
		from information_schema.partitions where table_name = \"$src\""`

	if $report ; then
		echo "$src (" `get_primary_key "$src"` ")"
		echo "$dest ("`get_primary_key "$dest"` ")"
	else
		echo "$src "
	fi

	#
	# get the current partition list
	#
	partitions=`get_partitions $src | sort -r`

	for part in $partitions ; do

		assert_active
		assert_space

		if $report ; then
			partition_report $src $dest $part
		else
			if ! partition_copy $src $dest $part ; then
				if [ $verbose -gt 0 ] ; then echo "partition_iterate: slept" ; fi
				return 1
			fi
		fi
	done
	return 0
}

#
# make the partitions in $2 match $1
#
function fix_partitions() {
	local src=$1
	local dest=$2

	if [ $verbose -gt 0 ] ; then echo "fix partitions $src"; fi
	#
	# delete any partitions in dest that no longer exist in src
	#
	srcparts=`get_parts_as_in $src`

	deletes=`sql "select distinct(partition_name) from information_schema.partitions \
		where table_name = \"$dest\" and \
		partition_name not in $srcparts"`
	for part in $deletes ; do
		if [ $verbose -gt 0 ] ; then echo "$dest: delete partition $part" ; fi
		sql "alter table $dest drop partition $part"
	done

	#
	# add partitions that are in src that are not in dest
	#
	destparts=`get_parts_as_in $dest`
	adds=`sql "select distinct(partition_name) from information_schema.partitions \
		where table_name = \"$src\" and \
		partition_name not in $destparts"`
	for part in $adds ; do
		limit=`sql "select distinct(partition_description) \
			from information_schema.partitions where \
			partition_name = \"$part\" and table_name = \"$src\""`
		if [ $verbose -gt 0 ] ; then echo "$dest: add partition $part at $limit" ; fi
		sql "alter table $dest reorganize partition PARTMAX into \
			(partition $part values less than ($limit), \
			 partition PARTMAX values less than MAXVALUE)"
	done
}

#
# copy table $1 with new primary key $2
# if the primary key is already installed, then do fixup
#
function convolve() {
	local src=$1
	local dest=fast_$1
	local oldkey=`get_primary_key "$src"`
	local newkey="$2"

	#
	# exit if there is a valid a per-table lock file
	# else create it.
	#
	lockfile=$lockdir/convolvelock.$src
	if [ -f $lockfile ] ; then
		pid=$(cat $lockfile)
		if [ -d /proc/$pid ] && \
			awk '/^Name:/ {print $2}' < /proc/$pid/status | \
			grep -w -s -q convolve.sh ; then
			echo "convolve already running as process $pid"
			exit 11
		fi		
	fi
	echo $$ > $lockfile

	hiwatermark=$avoid

	#
	# if new key has not been set yet
	#
	if [ $oldkey != $newkey ] ; then
		fix_parts=true
		save=old_$1

		#
		# report is a no-write case
		#
		if $report ; then
			fix_parts=false
			rename=false
		else
			if $new_tables ; then
				echo "force new table create"
				sql "drop table if exists $dest"
			fi
			local newcreate=`sql "select table_name from information_schema.tables \
				where table_name = \"$dest\""`
			if [ -z "$newcreate" ] ; then
				# create the destination table, editing the primary key
				newcreate=`get_create_table $src | 
					sed -e "s/($oldkey)/($newkey)/" -e "s/$src/$dest/"`
				if [ $verbose -gt 0 ] ; then echo creating $dest ; fi
				sql "$newcreate"
				# add a secondary index that matches the old primary key
				# so that select max(ts_min) and min(ts_min) still is fast.
				if [ ! -z `if_index_exists $dest ts_min_index` ] ; then
					sql "alter table $dest drop index ts_min_index"
				fi
				sql "alter table $dest add index ts_min_index ($oldkey)"
				# lose any index that matches the new primary
				if [ ! -z `if_index_exists $dest metric_id_time` ] ; then
					sql "alter table $dest drop index metric_id_time"
				fi
			fi
		fi

		if $truncate ; then
			if [ $verbose -gt 0 ] ; then echo "truncate source table $src" ; fi
			sql "truncate table $src"
		fi

		if $rename ; then
			if [ $verbose -gt 0 ] ; then echo "rename $src->$save, $dest->$src" ; fi
			sql "drop table if exists $save"
			sql "rename table $src to $save, $dest to $src"
			fix_parts=false
			dest=$src
			src=$save
		fi

	else
		echo "table $src already convolved"
		src=old_$1
		dest=$1
		fix_parts=false
	fi

	while true ; do

		if $fix_parts ; then
			fix_partitions $src $dest
		fi

		if partition_iterate $src $dest ; then
			break
		fi

	done
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
# let's do a trivial check for sql connectivity
#
if ! sql "show databases" | grep -q controller ; then
	echo "mysql connection failed"
	exit 8
fi

#
# actually do the work of convolving the metric tables
#
for table in $tables ; do
	if ! primary=`get_new_primary $table` ; then
		echo "$table unknown - skipping"
		continue
	fi
	convolve "$table" "$primary"
done

process_drain

echo -n 'finish convolving at ';
echo `date +%d/%m/%Y\ %H:%M:%S`;

if [ ! -c $errfile ] ; then
	if [ -s $errfile ]; then
		echo "errors: "
		uniq $errfile
	fi

	rm $errfile
fi

exit 0
