#!/bin/bash
#
# use this to perform a parallel dump or parallel load of a appdynamics controller database
# 
# $Id: controller_dbtool.sh 1.12 2020-08-29 15:52:50 robnav $

# For ease of deployment, locally embed/include function library at build time
FUNCLIB=dbfunctions.sh

###################### Start of embedded file: dbfunctions.sh
#!/bin/bash
#
# $Id: dbfunctions.sh 1.1 2015-10-05 12:22:17 rob.navarro $
#
# dbfunctions.sh
# contains common code used by the database functions toolkit
# 

# simple way to write message to STDERR and exit with non-zero return code
# call as:
#  err "some message" [optional return code]
function err {
   local exitcode=${2:-1}				# default to exit 1
   local c=($(caller 1))					# who called me?
   local r="${c[2]}(f=${c[1]},l=${c[0]})"			# where in code?

   echo "ERROR: $r failed: $1" 1>&2

   exit $exitcode
}

trap wait EXIT							# output before next cmd prompt

########################################################################
#
# !!!IMPORTANT!!!
# place here the tests for shell programs that must exist
#
########################################################################
which tee >/dev/null || err "unable to find 'tee' program. Please install and re-run."
which gawk >/dev/null || err "unable to find 'gawk' program. Please install and re-run."
########################################################################

# helper function to join array elements into string with named separator, 
# gleaned from:
# http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
function join { 
   local IFS="$1"
   shift
   echo "$*" 
}

# get lastmodified time in seconds since epoch given a file name
function get_mtime {
   (( $# < 1 )) && err "get_mtime function needs filename parameter"
   local mtime

   [[ -e $1 ]] || err "get_mtime: cannot access file: $1"
   local ostype=$(uname)
   if [[ $ostype == "Linux" ]]; then
      mtime=$(stat --format "%Y" $1)
   elif [[ $ostype == "Darwin" ]]; then			# running on MacOS
      local vals="$(stat -s $1)"
      local pattern='st_mtime=([0-9]+)'			# \d not supported
      [[ $vals =~ $pattern ]] || err "get_mtime could not find mtime within: $vals"
      mtime=${BASH_REMATCH[1]}
   fi

   echo $mtime
}

# get ISO date string from epoch seconds input. 
# Sadly too many Bash shells do not have printf with %(datefmt)T. Hence use gawk instead.
function get_iso_datetime {
   if (( $# == 0 )) ; then				# assume date in 'now'
      gawk 'BEGIN { print strftime( "%FT%T" ); exit 0 }' -
   else							# date is in $1
      local re='^[0-9]+$'
      [[ $1 =~ $re ]] || err "get_iso_datetime: expecting a numeric of seconds since epoch, got '$1'"
      gawk 'BEGIN { print strftime( "%FT%T", '$1' ); exit 0 }' -
   fi
}

# user function to mark rows that should go to logfile only (and not to STDOUT)
#
# call as:
#   logfile="somenicefile"
#   log_all_append_to $logfile
#   to_log < <( cmd 2>&1 )
#
function to_log {
   [[ $LOGALLSETUP == 1 ]] || err "to_log must be called after one of the log_all_*_to functions"
   local line

   while IFS= read -r line; do
      echo $'\035'$line
   done
}

# helper function send rows either to log file alone or both STDOUT and log file
function funnel_stdin {
   (( $# < 1 )) && err "funnel_stdin function needs string filename parameter"
   local line

   while IFS= read -r line; do
      if [[ ${line:0:1} == $'\035' ]]; then	# this row to log file only
         echo ${line:1} >> $1			# skipping first char
      else					# otherwise to STDOUT & log file
         echo $line
         echo $line >> $1
      fi
   done
}

# copy STDOUT and STDERR to named file, *overwriting* prior contents
# exec magic from http://stackoverflow.com/questions/363223/how-do-i-get-both-stdout-and-stderr-to-go-to-the-terminal-and-a-log-file
#
# call as:
#  logfile="/tmp/loggy"
#  log_all_overwrite_to $logfile  # all STDOUT and STDERR will now route to STDOUT and $logfile
#
function log_all_overwrite_to {
   (( $# < 1 )) && err "log_all_overwrite_to function needs string parameter"

   # dependencies OK? 
   # Need to create empty file...
   echo -n '' > $1 2>/dev/null || err "log_all_overwrite_to: unable to write to file: $1"

   exec > >(funnel_stdin $1) 2>&1
   LOGALLSETUP=1				# help prevent to_log failing
}

# copy STDOUT and STDERR to named file, *appending* to any prior contents
#
# call as:
#  logfile="/tmp/loggy"
#  log_all_append_to $logfile  # all STDOUT and STDERR will now route to STDOUT and $logfile
#
function log_all_append_to {
   (( $# < 1 )) && err "log_all_append_to function needs string parameter"

   # dependencies OK?
   touch $1 2>/dev/null || err "log_all_append_to: unable to write to file: $1"

   exec > >(funnel_stdin $1) 2>&1
   LOGALLSETUP=1				# help prevent to_log failing
}

# copy STDOUT and STDERR to named file, renaming any existing file with date suffix and then overwriting named one
#
# call as:
#  logfile="/tmp/loggy"
#  log_all_rename_to $logfile  # all STDOUT and STDERR will now route to STDOUT and $logfile
#
function log_all_rename_to {
   (( $# < 1 )) && err "log_all_rename_to function needs string parameter"

   if [[ -e $1 ]] ; then				# file already exists
      local mtime=$(get_mtime $1)			# last modified time
      local extn=$(get_iso_datetime $mtime)		# get nice extn string
      [[ -n $extn ]] || err "log_all_rename_to: unable to get datetime from file: $1"
      mv $1 "$1.$extn" || err "log_all_rename_to: unable to 'mv $1 $1.$extn'"
   fi

   # dependencies OK?
   touch $1 2>/dev/null || err "log_all_rename_to: unable to write to file: $1"

   exec > >(funnel_stdin $1) 2>&1
   LOGALLSETUP=1				# help prevent to_log failing
}
###################### End of embedded file: dbfunctions.sh


dump_partitioned=false
appd=/opt/appdynamics/controller
dest=
load=false
COMPRESS=true
logfname=controller_repair.log			# default assumes dump

if [ -x /usr/bin/nproc ] ; then
	joblimit=`/usr/bin/nproc`
elif [ -x /usr/sbin/sysctl ] ; then
	joblimit=`/usr/sbin/sysctl -n hw.ncpu`
else
	joblimit=20
	echo "default joblimit is $joblimit"
fi

function usage() {
	echo usage:
	echo $0 "[<args>]"
	echo "  -d <destdir>                dump directory"
	echo "  -r <appdynamics root dir>   controller install directory (default $appd)"
	echo "  -p                          dump partitioned data in addition to metadata"
	echo "  -l                          do load instead of dump"
	echo "  -P <n>                      set dump parallelism (default $joblimit)"
	echo "  -c                          compress"
	echo "  -s                          no archives, audit, file-content or incidents"
}

while getopts "sld:r:P:pnhc" opt; do
	case $opt in
	l)
		load=true
		logfname=controller_load.log	# we want to do load not dump
		;;
   	p)
		dump_partitioned=true
		;;
   	r)
		appd=$OPTARG
      		;;
   	c)
		COMPRESS=gzip
		;;
   	d)
		dest=$OPTARG
		;;
   	P)
		joblimit=$OPTARG
		;;
	h)
		usage
		exit
		;;
	s)
		extra_ignores=(
			file_content
			eventdata_archive_affected
			eventdata_archive_correlation_key
			eventdata_archive_detail
			eventdata_archive_min
			process_snapshot_archive_properties
			requestdata_archive_exitcall
			requestdata_archive_properties
			requestdata_archive_summary
			eventdata_archive_affected
			eventdata_archive_correlation_key
			eventdata_archive_detail
			eventdata_archive_min
			process_snapshot_archive_properties
			requestdata_archive_exitcall
			requestdata_archive_properties
			requestdata_archive_summary
			policy_evaluation_state
			incident
			file_content
			file
			controller_audit
		)
			;;
		\?)
			echo "Invalid option: -$OPTARG"
			usage
			exit
				;;
		esac
	done

if [ -z "$dest" ] ; then
	echo must specify dump directory
	exit
fi

if [ ! -d $dest ] ; then
	echo "creating directory $dest"
	mkdir -p $dest
fi

logfile=$dest/$logfname
log_all_rename_to $logfile				# log both STDOUT and STDERR, renaming any existing file
echo "$0 $* starting $(date)"

#
# some sanity checks
#
if [ ! -d $appd ] ; then
	$appd directory does not exist!
	exit -1
fi

if [ ! -x $appd/bin/controller.sh ] ; then
	$appd/bin/controller.sh file does not exist!
	exit -1
fi

mysql=$appd/db/bin/mysql
mysqldump=$appd/db/bin/mysqldump

#
# get the mysql password - version dependent
#
mysql_password=`grep ^mysql_root_user_password $appd/bin/controller.sh | awk -F= '{print $2}'`
if [ -z "$mysql_password" ] ; then
	if [ -f $appd/db/.rootpw ] ; then
		mysql_password=`cat $appd/db/.rootpw`
	else
		mysql_password=singcontroller
	fi
fi

mysql_port=`grep ^DB_PORT $appd/bin/controller.sh | awk -F= '{print $2}'`
if [ -z "$mysql_port" ] ; then
	mysql_port=3388
fi

connect="--user=root --password=$mysql_password --port=$mysql_port --protocol=TCP"

datadir=`grep ^datadir $appd/db/db.cnf | cut -d = -f 2`
if [ -z "$datadir" ] ; then
	datadir=$appd/db/data
fi

if [ $load == false ] ; then
	#
	# trash the destination directory
	#
	rm -f $dest/*.sql

	partitioned=(`ls -1 $datadir/controller/*PARTMAX*.ibd | sed -e 's/#.*$//' -e 's,^.*/,,' | sort -u`)
	# partitioned=(metricdata_min)
	ignorelist=--ignore-table=controller.ejb__timer__tbl
	for t in ${partitioned[@]} ; do
		ignorelist="$ignorelist --ignore-table=controller.$t"
	done;
	for t in ${extra_ignores[@]} ; do
		ignorelist="$ignorelist --ignore-table=controller.$t"
	done

	echo "  -- dumping metadata"
#	echo $mysqldump -v --single-transaction --result-file=$dest/metadata_dump.sql $connect $ignorelist controller >> $logfile
#	$mysqldump -v --single-transaction --result-file=$dest/metadata_dump.sql $connect $ignorelist controller >> $logfile 2>&1
	to_log < <(echo $mysqldump -v --single-transaction --skip-lock-tables --set-gtid-purged=off --routines --result-file=$dest/metadata_dump.sql $connect $ignorelist --databases controller $(cd $datadir; ls -d eum* mds* 2>/dev/null))
        to_log < <($mysqldump -v --single-transaction --skip-lock-tables --set-gtid-purged=off --routines --result-file=$dest/metadata_dump.sql $connect $ignorelist --databases controller $(cd $datadir; ls -d eum* mds* 2>/dev/null) 2>&1)
	$COMPRESS $dest/metadata_dump.sql

	if [ $dump_partitioned == true ] ; then
		for t in ${partitioned[@]} ; do
			create_file=create-table-${t}.sql
			echo "  -- producing create table file for $t"
#			echo $mysqldump -v -d --result-file=/tmp/$create_file $connect controller $t >> $logfile
			to_log < <(echo $mysqldump -v -d --result-file=/tmp/$create_file $connect controller $t)
			$mysqldump -v -d --result-file=/tmp/$create_file $connect controller $t 2>/dev/null
			key=`grep "PARTITION BY RANGE" /tmp/$create_file | sed -e 's/^.*(//' -e 's/).*$//'`
			pa=(`tr -d '()' < /tmp/$create_file | awk '/VALUES LESS THAN/ { print $2 }'`)
			lim=(`tr -d '()' < /tmp/$create_file | awk '/VALUES LESS THAN/ { print $6 }'`)
			sta=(`tr -d '()' < /tmp/$create_file | awk 'BEGIN {s=0} /VALUES LESS THAN/ { print s; s=$6 }'`)
			((i=0))
			njobs=0
			for p in ${pa[@]} ; do
				if [ ${lim[$i]} = MAXVALUE ] ; then
					where="$key >= ${sta[$i]}"
				elif [ ${sta[$i]} = 0 ] ; then
					where="$key < ${lim[$i]}"
				else
					where="$key >= ${sta[$i]} and $key < ${lim[$i]}"
				fi
				((i++))
				result=$dest/${t}_${p}_dump
				echo "  -- dumping partition $p for $t"
#				echo $mysqldump --compact -c -e -t --order-by-primary --result-file=$result.data --where="$where" $connect controller $t >> $logfile
				to_log < <(echo $mysqldump --compact -c -e -t --order-by-primary --result-file=$result.data --where="$where" $connect controller $t)
				echo "alter table ${t} truncate partition ${p};" >$result.prefix
#				( $mysqldump --compact -c -e -t --order-by-primary --result-file=$result.data --where="$where" $connect controller $t >> $logfile 2>&1 ;				  cat $result.prefix $result.data > $result.sql ; rm $result.prefix $result.data ; $COMPRESS $result.sql ) &
				( to_log < <($mysqldump --compact -c -e -t --order-by-primary --result-file=$result.data --where="$where" $connect controller $t 2>&1) ;				  cat $result.prefix $result.data > $result.sql ; rm $result.prefix $result.data ; $COMPRESS $result.sql ) &
				(( njobs ++ ))
				if [ $njobs -ge $joblimit ] ; then
					wait
					njobs=0
				fi
			done
			if [ $dest != /tmp ] ; then
				mv /tmp/$create_file $dest/$create_file
			fi
			wait
			njobs=0
		done
		for f in $dest/*_dump.sql ; do
			if [ -e $f -a ! -s $f ] ; then
				rm $f
			fi
		done
	fi
	echo "$0 $* ended $(date)"
fi

function loadfile() {
	if [[ $1 = *.gz ]] ; then
		gunzip -c -d $1 | $mysql $connect controller
	else
		cat $1 | $mysql $connect controller
	fi
	mv $1 $dest/done
}

#
# load the schema create, table creates, and data rows
#
if [ $load == true ] ; then
	mkdir -p $dest/done

	if [ -f $dest/create-schema.sql ] ; then
		echo "  -- creating schema"
		$mysql $connect -e "source $dest/create-schema.sql" controller
		mv $dest/create-schema.sql $dest/done
	fi

	for t in $dest/create-table-*.sql ; do
		if [ -f $t ] ; then
			echo "  -- creating table from $t"
			( $mysql $connect -e "source $t" controller ; mv $t $dest/done) &
		fi
	done
	wait

	for t in $dest/metadata_dump.sql* ; do
		if [ -f $t ] ; then
			echo "  -- loading metadata"
			loadfile $t
			break;
		fi
	done

	# build the work list in the following way: tables interleaved - maximizes concurrency loading
	worklist=`\
		cd $dest ; \
		find . -maxdepth 1 -name '*PART*_dump.sql*' -print | \
		awk '{ sub("^./",""); t=$1; sub("_PART.*","",t); tn[t]++; print $1,tn[t];}' | \
		sort -k 2n | \
		awk '{print $1}' \
	`

	filecount=`echo $worklist | wc -w`
	active=
	
	for t in ${worklist[@]} ; do

		# crack the filename
		partfile=`basename $t`
		table=`echo $partfile | sed -e 's/_PART.*//'`
		partition=`echo $partfile | sed -e 's/.*_\(PART[^_]*\)_dump.*/\1/'`

		# if we are working on this table already, wait for the jobs to drain out
		if echo "$active" | grep -w -q "$table" ; then
			wait
			active=
		fi
	
		# append this table to our active list
		active="$active $table"

		echo "  -- loading $t $filecount"
		(( filecount -- ))
		loadfile $dest/$t &
	done
	wait
	echo "$0 $* ended $(date)"
	exit
fi
