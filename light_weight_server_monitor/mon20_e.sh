#!/bin/bash

# kick off light monitoring of current server - endlessly or for fixed period
# Main design goals have evolved to be:
# - very low server impact << 1% CPU 
# - stats reliably output
# - easy to read on server (implying more tricky to parse)
#
# Logs process IDs to $LOGDIR/*mon[0-9]?.pid for easier killing 
# but saves only the PIDs from the last startup. Running multiple
# copies of this script concurrently will only save one set of PIDs
# 
# Build release with:
#  cd scripts
#  perl ../customer_success/tools/embed.pl < mon.sh > mon_e.sh
#
#						ran 11-Oct-2016
#
# Updated to remove evil race condition between replication and running
# script. Controller.mq* tables are currently not replicated.
#						ran 27-Oct-2016
#
# Generalised to scrape all block device names and accept ticket number
# at invocation time.
#						ran 19-Dec-2016
#
# extended to allow selected monitors to run or exclude
#						ran 27-Feb-2017
#
# added run_dbvars and ability to stop-after named time period
#						ran 13-May-2017
# 
# modified to run with older vmstat that has no '-t' timestamp option
# and fetch peak VM usage rather than just current VM size
#						ran 6-Jun-2017
#
# modified to also run on older 3.2.57+ versions of Bash 
#						ran 28-Aug-2017
#
# added monitor for network port connection count
#						ran 06-Nov-2017
#
# fixed bug that surfaces when multiple MySQL servers are running
# and change memsize to use peak RSS and include total free
#						ran 21-Nov-2017
# 
# fixed missing single quotes bug in dbvars monitor
#						ran 13-Dec-2017
#						
# stop DB connect error messages from logging to console when DB down
#						ran 12-Mar-2018
#
# add in NUMA specific monitors
#						ran 01-Jun-2018
#
# embedded MySQL client access using obfuscated password to
# cope with case when no HA Toolkit deployed
#						ran 17-Jul-2018
#
# minor bug fix that prevented DB monitors from using db/.rootpw 
# with MySQL v5.7 
#                                               ran 21-Dec-2018
#
# added ability to include slowlogmetric.pl outputs in a light
# weight manner
#						ran Feb-2019

PROGNAME=${0##*/}
STEMNAME=${PROGNAME%%.*}
STARTTM=$(date +%s)
TICKETNM=
HOST=$(hostname)
LOGDIR=/var/tmp

#  err "some message" [optional return code]
function err {
   local exitcode=${2:-1}                               # default to exit 1
   local c=($(caller 0))                                        # who called me?
   local r="${c[2]} (f=${c[1]},l=${c[0]})"                       # where in code?

   echo "ERROR: $r failed: $1" 1>&2

   exit $exitcode
}
function warn {
   echo "WARN: $1" 1>&2
}

# For ease of deployment, locally embed/include function library at build time
# Provides:
#   mysqlclient, persist_mysql_passwd
FUNCLIB=../obfus_lib.sh

###################### Start of embedded file: ../obfus_lib.sh
#!/bin/bash

# definitive obfuscate/deobfuscate library for separate inclusion where needed
#
# Use/include in other scripts by:
#  function err { # <string> <optional return code> }
#  function warn { # <string> }
#  . obfus_lib.sh
#
#  created lib
#							ran 06-Aug-2018
#

declare -F err &> /dev/null || { echo "function with prototype 'err <str> <optional ret code> ' must be defined for obfus_lib.sh" 1>&2; exit 1; }
declare -F warn &> /dev/null || { echo "function with prototype 'warn <str>' must be defined for obfus_lib.sh" 1>&2; exit 1; }

if [ "`uname`" == "Linux" ] ; then
	BASE64_NO_WRAP="-w 0"
else
	BASE64_NO_WRAP=""
fi

##  err "some message" [optional return code]
#function err {
#   local exitcode=${2:-1}                               # default to exit 1
#   local c=($(caller 0))                                        # who called me?
#   local r="${c[2]} (f=${c[1]},l=${c[0]})"                       # where in code?
#
#   echo "ERROR: $r failed: $1" 1>&2
#
#   exit $exitcode
#}
#function warn {
#   echo "WARN: $1" 1>&2
#}

function debug
{
   while read -p '?dbg> ' L ; do
      eval "$L"
   done < /dev/stdin
}

# one of pair of low level functions {obf,deobf}_<some extention>
# Expected to output to STDOUT:
#  ofa1 <obfuscated value of input parameter>
#
# Call as:
#  obf_ofa1 <data>
function obf_ofa1 {
	local thisfn=${FUNCNAME[0]} step1 obf
	(( $# == 1 )) || err "Usage: $thisfn <clear_data>"

	step1=$(tr '\!-~' 'P-~\!-O' < <(echo -n $1)) || exit 1
	[[ -n "$step1" ]] || err "produced empty step1 obfuscation" 2
	obf=$(base64 $BASE64_NO_WRAP < <(echo -n $step1)) || exit 1
	[[ -n "$obf" ]] || err "produced empty obfuscation" 3

	# use part of function name after last '_' as obfuscator type
	echo "${thisfn##*_} "$obf
}
export -f obf_ofa1

# one of pair of low level functions {obf,deobf}_<some extention>
# Expected to output to STDOUT:
#  <deobfuscated value of input parameter>\n
# Call as:
#  deobf_ofa1 <data>
function deobf_ofa1 {
	local step1 clear
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <obf_data>"

	step1=$(base64 --decode $BASE64_NO_WRAP < <(echo -n $1)) || exit 1
	[[ -n "$step1" ]] || err "produced empty step1 deobfuscation" 2
	clear=$(tr '\!-~' 'P-~\!-O' < <(echo -n $step1)) || exit 1
	[[ -n "$clear" ]] || err "produced empty cleartext" 3

	echo $clear
}
export -f deobf_ofa1

# one of pair of low level functions {obf,deobf}_<some extention>
# Expected to output to STDOUT:
#  ofa2 <obfuscated value of input parameter>
#
# Call as:
#  obf_ofa2 <data>
function obf_ofa2 {
	local thisfn=${FUNCNAME[0]} step1 otype obf
	(( $# == 1 )) || err "Usage: $thisfn <clear_data>"

	obf=$(tr 'A-Za-z' 'N-ZA-Mn-za-m' < <(echo -n $1)) || exit 1
	[[ -n "$obf" ]] || err "produced empty obfuscation" 2

	# use part of function name after last '_' as obfuscator type
	echo "${thisfn##*_} "$obf
}
export -f obf_ofa2

# one of pair of low level functions {obf,deobf}_<some extention>
# Expected to output to STDOUT:
#  <deobfuscated value of input parameter>\n
# Call as:
#  deobf_ofa2 <data>
function deobf_ofa2 {
	local step1 clear
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <obf_data>"

	clear=$(tr 'A-Za-z' 'N-ZA-Mn-za-m' < <(echo -n $1)) || exit 1
	[[ -n "$clear" ]] || err "produced empty cleartext" 2

	echo $clear
}
export -f deobf_ofa2

# overall wrapper function for obfuscation 
# Call as
#  obfuscate <obf type> <data>
# or
#  obfuscate <data>
function obfuscate {
	local data otype
	(( $# == 1 || $# == 2 )) || err "Usage: ${FUNCNAME[0]} [<obf type>] <data>"

	if (( $# == 2 )) ; then
		otype=$1
		data=$2
	else
		otype=''
		data=$1
	fi
	case $otype in
		ofa1 | '' )	obf_ofa1 "$data" ;;	# default case
		ofa2)		obf_ofa2 "$data" ;;
		*)		err "unknown obfuscation type \"$otype\"" ;;
	esac
}
export -f obfuscate

# overall wrapper for various de-obfuscator functions
# Call as:
#  deobfuscate <otype> <obf_data>
function deobfuscate {
	local otype=$1 data=$2
	(( $# == 2 )) || err "Usage: ${FUNCNAME[0]} <obf type> <obf_data>"

	case $otype in
		ofa1)	deobf_ofa1 "$data" ;;
		ofa2)	deobf_ofa2 "$data" ;;
		*)	err "unknown obfuscation type \"$otype\"" ;;
	esac
}
export -f deobfuscate

# with help from:
# http://stackoverflow.com/questions/1923435/how-do-i-echo-stars-when-reading-password-with-read
function getpw { 
        (( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <variable name>"
        local pwch inpw1 inpw2=' ' prompt; 
        
        ref=$1 
	while [[ "$inpw1" != "$inpw2" ]] ; do
		prompt="Enter MySQL root password: "
		inpw1=''
		while IFS= read -p "$prompt" -r -s -n1 pwch ; do 
			if [[ -z "$pwch" ]]; then 
				[[ -t 0 ]] && echo 
				break 
			else 
				prompt='*'
				inpw1+=$pwch 
			fi 
		done 

		prompt="re-enter same password: "
		inpw2=''
		while IFS= read -p "$prompt" -r -s -n1 pwch ; do 
			if [[ -z "$pwch" ]]; then 
				[[ -t 0 ]] && echo
				break 
			else 
				prompt='*'
				inpw2+=$pwch 
			fi 
		done 
	
		[[ "$inpw1" == "$inpw2" ]] || echo "passwords unequal. Retry..." 1>&2
	done

	# indirect assignment (without local -n) needs eval. 
	# This only works with global variables :-( Please use weird variable names to
	# avoid namespace conflicts...
        eval "${ref}=\$inpw1"            # assign passwd to parameter variable
}
export -f getpw

# helper function to allow separate setting of passwd from command line.
# Use this to persist an obfuscated version of the MySQL passwd to disk.
function save_mysql_passwd {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <APPD_ROOT>"

	local thisfn=${FUNCNAME[0]} APPD_ROOT=$1 
	[[ -d $1 ]] || err "$thisfn: \"$1\" is not APPD_ROOT"
	local rootpw_obf="$APPD_ROOT/db/.rootpw.obf"

	getpw __inpw1 || exit 1		# updates __inpw1 *ONLY* if global variable
	obf=$(obfuscate "$__inpw1") || exit 1
	echo $obf > $rootpw_obf || err "$thisfn: failed to save obfuscated passwd to $rootpw_obf"
	chmod 600 $rootpw_obf || warn "$thisfn: failed to make $rootpw_obf readonly"
}
export -f save_mysql_passwd

###
# get MySQL root password in a variety of ways.
# 1. respect MYSQL_ROOT_PASSWD if present; please pass down to sub-scripts. 
#    Do NOT persist to disk.
# 2. respect $APPD_ROOT/db/.rootpw if present
# 3. respect $APPD_ROOT/db/.rootpw.obf if present
# 4. respect $APPD_ROOT/db/.mylogin.cnf if present and MYSQL_TEST_LOGIN_FILE defined
# 5. gripe, letting them know how to persist a password
#
# Call as:
#  dbpasswd=`get_mysql_passwd`
function get_mysql_passwd {
	if [[ -z "$APPD_ROOT" ]] ; then
		[[ -f ./db/db.cnf ]] || err "unable to find ./db/db.cnf. Please run from controller install directory."
		export APPD_ROOT="$(pwd -P)"
	fi
	local clear obf otype inpw2=' '
	local rootpw="$APPD_ROOT/db/.rootpw" rootpw_obf="$APPD_ROOT/db/.rootpw.obf"
	local mysqlpw="$APPD_ROOT/db/.mylogin.cnf"

	if [[ -n "$MYSQL_ROOT_PASSWD" ]] ; then
		echo $MYSQL_ROOT_PASSWD
	elif [[ -s $rootpw && -r $rootpw ]] ; then 
		echo $(<$rootpw)
	elif [[ -s $rootpw_obf ]] ; then
		IFS=$' ' read -r otype obf < $rootpw_obf
		[[ -n "$otype" && -n "$obf" ]] || \
			err "unable to read obfuscated passwd from $rootpw_obf"
		clear=$(deobfuscate $otype $obf)
		[[ -n "$clear" ]] || \
			err "unable to deobfuscate passwd from $rootpw_obf" 2
		echo $clear
	elif [[ -s $mysqlpw ]] ; then
	   	# sneaky way to get MySQL tool: mysql_config_editor to write its encrypted .mylogin.cnf
	   	# to a place that is guaranteed to exist. Some clients have no writeable user home 
	   	# directory !
	   	export MYSQL_TEST_LOGIN_FILE=$APPD_ROOT/db/.mylogin.cnf

		clear=$(awk -F= '$1 ~ "word" {print $2}' <<< "$($APPD_ROOT/db/bin/my_print_defaults -s client)")
		[[ -n "$clear" ]] || err "unable to get passwd from $mysqlpw" 3
		echo $clear
	else
		err "no password in MYSQL_ROOT_PASSWORD, db/.rootpw, db/.rootpw.obf or db/.mylogin.cnf please run save_mysql_passwd.sh" 3
	fi
}
export -f get_mysql_passwd

# if MySQL root password not already available (ENV variable or on disk), then write it to disk in obfuscated form. 
# Extension of script HA/save_mysql_passwd.sh
function persist_mysql_passwd {
	[[ -f ./db/db.cnf ]] || err "unable to find ./db/db.cnf. Please run from controller install directory."
	export APPD_ROOT="$(pwd -P)"

	#
	# prerequisites - die immediately if not present
	#
	type tr &> /dev/null || err "needs \'tr\'" 2
	type base64 &> /dev/null || err "needs \'base64\'" 3
	type awk &> /dev/null || err "needs \'awk\'" 4

	dbpasswd=$(get_mysql_passwd 2> /dev/null)	# ignore return 1 and err msg if no passwd

	if [[ -n "$dbpasswd" ]] ; then			# nothing to do ... just save & return
		export dbpasswd
		return 0
	fi

	# given no MySQL root password was found, now prompt user for it and persist to disk
	if [[ -x $APPD_ROOT/db/bin/mysql_config_editor ]] ; then
	   	# sneaky way to get MySQL tool: mysql_config_editor to write its encrypted .mylogin.cnf
	   	# to a place that is guaranteed to exist. Some clients have no writeable user home 
	   	# directory !
	   	export MYSQL_TEST_LOGIN_FILE=$APPD_ROOT/db/.mylogin.cnf

		$APPD_ROOT/db/bin/mysql_config_editor reset
		$APPD_ROOT/db/bin/mysql_config_editor set --user=root -p
	else
		save_mysql_passwd $APPD_ROOT
	fi
}
export -f persist_mysql_passwd

function get_dbport {
	if [[ ! -f ./db/db.cnf ]] ; then
		err "unable to find ./db/db.cnf. Please run from controller install directory."
		return 1
	fi

	awk -F= '$1 =="port" {print $2}' ./db/db.cnf
}
export -f get_dbport

# simple wrapper for MySQL client
function mysqlclient {
	DBPORT=${DBPORT:-$(get_dbport)} || return 1
	local CONNECT=(--host=localhost --protocol=TCP --user=root --port=$DBPORT)
	APPD_ROOT=${APPD_ROOT:-"$(pwd -P)"}		# assumes directory checked earlier
	export MYSQL_TEST_LOGIN_FILE=${MYSQL_TEST_LOGIN_FILE:-$APPD_ROOT/db/.mylogin.cnf}
	if [[ ! -f $APPD_ROOT/db/.mylogin.cnf ]] ; then
		dbpasswd=${dbpasswd:-$(get_mysql_passwd 2> /dev/null)} || err "MySQL password not already persisted. Please re-run without -n parameter to do that"
		CONNECT+=("--password=$dbpasswd")
	fi
	./db/bin/mysql -A "${CONNECT[@]}" controller
}
export -f mysqlclient
###################### End of embedded file: ../obfus_lib.sh


# unchanged lines 48-79 of github/controllertools/slowlogmetric.pl of Feb-2019 version
# Can change number of parse blocks and pause interval with optional parameters:
#   parse_slowlog 500 5  # 500 blocks read with 5 second pause thereafter
function parse_slowlog {
   perl -se '
use warnings;
#use strict;
# unchanged slowlogmetric.pl below
$/ = "# User\@Host: ";                  # read in blocks delimited by this string

my $insert_cmd1 = qr{LOAD DATA CONCURRENT LOCAL INFILE .dummy.txt. IGNORE INTO TABLE metricdata_min FIELDS};    # 2012 syntax
my $insert_cmd2 = qr{.. .. LOAD DATA CONCURRENT LOCAL INFILE .dummy.txt. IGNORE INTO TABLE metricdata_min FIELDS}; # 2012 syntax
my $insert_cmd3 = qr{INSERT IGNORE INTO metricdata_min\s+SELECT};       # 4.2 syntax
my $insert_cmd = qr/(?:$insert_cmd1)|(?:$insert_cmd2)|(?:$insert_cmd3)/;

print "timestamp,avg_query_tm,avg_lock_tm,rows\n" if $csv_needed;

my $blocks_read = 0;
while (defined (my $block = <STDIN>) ) {
   ++$blocks_read;
   while ($block =~ m/# Query_time: (\S+)\s+Lock_time: (\S+).*?Rows_examined: (\d+).*?SET timestamp=(\d+);\s+${insert_cmd}/msgc) {
      my $query_tm = $1;
      my $lock_tm = $2;
      my $rows_ex = $3;
      my $esecs = $4;

      my @struct_tm = localtime( $esecs );
      my $datetm = sprintf("%4d-%02d-%02dT%02d:%02d:%02d", $struct_tm[5]+1900, $struct_tm[4]+1, $struct_tm[3],
                                                           $struct_tm[2], $struct_tm[1], $struct_tm[0]);

      if ($csv_needed) {
         print "$datetm,$query_tm,$lock_tm,$rows_ex\n" if $query_tm > $thresh_secs;
      } else {
         print "$datetm\tquery_tm=$query_tm\tlock_tm=$lock_tm\trows=$rows_ex\n" if $query_tm > $thresh_secs;
      }
   }
   if ($pause_blocks > 0) {
      sleep $pause_secs if ($blocks_read % $pause_blocks) == 0;
   }
}' -- -thresh_secs=0 -pause_blocks=${1:-400} -pause_secs=${2:-10} -csv_needed=0
}

function mk_logname {
	(( $# == 1 )) || err "mk_logname: needs function name arg"
	local FN=${1:-MISSING_FUNCNAME}
	echo "${LOGDIR}/${TICKETNM}_${FN}_${HOST}_${STARTTM}.txt"
}
export -f mk_logname

# return 0 if can get useful mysql client job, else 1
function check_db_connection {
	timeout 59s bash -c 'T=$(mysqlclient <<< "select '\''YESCON'\''" 2>&1); [[ "$T" =~ YESCON$ ]] || exit 123'
	R=$? 
	if (( $R == 123 )) ; then
		warn "Can't check connect to MySQL server on 'localhost' retc=$R"
		return 1
	elif (( $R == 124 )) ; then
		warn "DB check timed out retc=$R"
		return 1
	else
		return 0
	fi
}

# Will start an endlessly running program to output to specific log file.
# PID saved to simplify killing when needed.
function run_iostat {
	local FN=iostat
	local LOGF=$(mk_logname $FN)

	# verify that required programs are installed
	type iostat &> /dev/null || { warn "unable to find sysstat package 'iostat'. Disabling iostat monitor."; return 1; }
	local DEVS=$(lsblk -dln | awk '$1 ~ /^sd/ {print $1}')
	local interval=60
	local count=$(( ($DEADLINE - $STARTTM)/$interval ))
	( iostat -tzmx $DEVS $interval $count > $LOGF ) &
}

function run_vmstat {
	local FN=vmstat
	local LOGF=$(mk_logname $FN)

	# verify that required programs are installed
	type awk vmstat &> /dev/null || { warn "unable to find awk and vmstat commands. Disabling $FN monitor."; return 1; }

	local interval=30
	local count=$(( ($DEADLINE - $STARTTM)/$interval ))
	# need to flush STDOUT to ensure unbuffered & continuous output via pipe and redirection
	( awk 'BEGIN {cmd="vmstat '"$interval $count"'"; while (( cmd | getline ) > 0) {print $0" "strftime("%Y-%m-%dT%T"); fflush()}}' > $LOGF ) &
}

function run_dbtest {
	local FN=dbtest
	local LOGF=$(mk_logname $FN)

	# verify that running from controller install directory
#	[[ -n "$(get_mysql_passwd 2> /dev/null)" ]] || { warn "unable to find MySQL password. Disabling $FN monitor."; return 1; }
	check_db_connection 2>/dev/null || { warn "unable to connect to MySQL. Disabling $FN monitor."; return 1; }

	( while true ; do
		sleep 0.9
		(( $(date +%s) % 60 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		timeout 59s bash -c 'V=$(mysqlclient <<< "
drop table if exists mq_watchdog_test2_table;
create table mq_watchdog_test2_table (i int);
insert into mq_watchdog_test2_table values (1);
select count(*) from mq_watchdog_test2_table;
drop table mq_watchdog_test2_table;
" 2>&1); R=$?; echo $(date +'%FT%T') \"$V\" retc=$R >> '"$LOGF"
		R=$? 
		(( $R == 124 )) && echo $(date +'%FT%T') \"DB test timed out\" retc=$R >> $LOGF
		sleep 0.1
	done ) &
}

function run_dbvars {
	local FN=dbvars
	local LOGF=$(mk_logname $FN)
	declare -a vars 

	# verify that running from controller install directory
#	[[ -n "$(get_mysql_passwd 2> /dev/null)" ]] || { warn "unable to find MySQL password. Disabling $FN monitor."; return 1; }
	check_db_connection 2>/dev/null || { warn "unable to connect to MySQL. Disabling $FN monitor."; return 1; }

	# verify that required programs are installed
	type awk &> /dev/null || { warn "unable to find awk command. Disabling $FN monitor."; return 1; }

	( while true ; do
		sleep 0.9
		(( $(date +%s) % 60 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		timeout 59s bash -c ' 
eval $(awk '\''NF==2 {print "array_"$1"="$2}'\'' < <(mysqlclient <<< "show global status") )
declare -a mv=(Queries Aborted_clients Aborted_connects Connections Created_tmp_tables Created_tmp_disk_tables)
eval $(awk '\''BEGIN { print "declare -a vars=( " } { print $1"=${array_"$1"} " } END { print ")" }'\'' <<< "$(printf '\''%s\n'\'' ${mv[*]})" )
IFS=, ; echo -e "${vars[*]}\t$(date +'%FT%T')" >> '"$LOGF"
		R=$? 
		(( $R == 124 )) && echo $(date +'%FT%T') \"DB vars check timed out\" retc=$R >> $LOGF
		sleep 0.1
	done ) &
}

# display how many open file descriptors are used by Glassfish & MySQL
function run_fdcount {
	local FN=fdcount
	local LOGF=$(mk_logname $FN)

	# verify that running from controller install directory
	[[ -f ./db/db.cnf ]] || { warn "unable to find ./db/db.cnf. Please run from controller install directory. Disabling $FN monitor."; return 1; }
	# verify that required programs are installed
	type awk &> /dev/null || { warn "unable to find awk command. Disabling $FN monitor."; return 1; }

	( while true ; do
		sleep 1
		(( $(date +%s) % 60 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		local mysqlpid=$(pgrep -f "[m]ysqld .*--port=$(awk -F= '$1 == "port" {print $2}' db/db.cnf)") 
		local gfpid=$(pgrep -f "[g]lassfish.jar .*-javaagent:")
		local sql gf
		if [[ -n "${mysqlpid:-}" ]] ; then
			sql="$(ls -1 /proc/$mysqlpid/fd | wc -l)"
		else
			sql="NO_MYSQL_RUNNING"
		fi
		if [[ -n "${gfpid:-}" ]] ; then
			gf="$(ls -1 /proc/$gfpid/fd | wc -l)"
		else
			gf="NO_GLASSFISH_RUNNING"
		fi
		echo -e "gf_fdcount=$gf\tmysql_fdcount=$sql\t$(date +'%FT%T')" >> $LOGF
	done ) &
}

# what is peak RSS and current RSS (see man 1 ps) for Glassfish and MySQL
function run_memsize {
	local FN=memsize
	local LOGF=$(mk_logname $FN)

	# verify that running from controller install directory
	[[ -f ./db/db.cnf ]] || { warn "unable to find ./db/db.cnf. Please run from controller install directory. Disabling $FN monitor."; return 1; }
	# verify that required programs are installed
	type awk &> /dev/null || { warn "unable to find awk command. Disabling $FN monitor."; return 1; }

	( while true ; do
		sleep 1
		(( $(date +%s) % 30 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		local mysqlpid=$(pgrep -f "[m]ysqld .*--port=$(awk -F= '$1 == "port" {print $2}' db/db.cnf)") 
		local gfpid=$(pgrep -f "[g]lassfish.jar .*-javaagent:")
		local sql gf rss vsz os
		if [[ -n "${mysqlpid:-}" ]] ; then
#			IFS=$' ' read rss vsz <<< $(ps -p $mysqlpid -orss=,vsz=)
#			sql="$(( rss/1024 ))m,$(( vsz/1024 ))m"
			sql="$(awk '$1=="VmHWM:" {peak=$2} $1=="VmRSS:" {rss=$2} END {printf "%.0fm,%.0fm\n",rss/1024,peak/1024}' /proc/$mysqlpid/status)"
		else
			sql="NO_MYSQL_RUNNING"
		fi
		if [[ -n "${gfpid:-}" ]] ; then
#			IFS=$' ' read rss vsz <<< $(ps -p $gfpid -orss=,vsz=)
#			gf="$(( rss/1024 ))m,$(( vsz/1024 ))m"
			gf="$(awk '$1=="VmHWM:" {peak=$2} $1=="VmRSS:" {rss=$2} END {printf "%.0fm,%.0fm\n",rss/1024,peak/1024}' /proc/$gfpid/status)"
		else
			gf="NO_GLASSFISH_RUNNING"
		fi
		os=$(awk '$2 ~/cache:$/ { bfree=$4 } $1 == "Swap:" { sused=$3 } END {printf "%.0fm,%.0fm\n",bfree/1024,sused/1024}' <<< "$(free -k)")
		[[ -n "$os" ]] || os="NO_FREE_OUTPUT"

		echo -e "gf_rss_prss=$gf\tmysql_rss_prss=$sql\tos_bfree_sused=$os\t$(date +'%FT%T')" >> $LOGF
	done ) & 
}

# helper function to scan domain.xml for named network-listener port number
# Call as:
#  P=$(get_dmnxml_listen_port http-listener-1) || exit 1
#  if [[ -n "$P" ]] ; then
#     process $P
#  fi
function get_dmnxml_listen_port {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <network-listener name>"
	local ln=$1 domainxml="./appserver/glassfish/domains/domain1/config/domain.xml"
	[[ -r "$domainxml" ]] || return 0

	awk -F": " '$0 ~ /Object is a number/ {print $2}' <<< "$(xmllint --shell $domainxml <<< 'xpath number(//network-listener[@name="'$ln'"]/@port)')"
}
export -f get_dmnxml_listen_port

# output number of connections for each of http-
function port_count {
	local FN=conxcount
	local LOGF=$(mk_logname $FN)
	local domainxml="./appserver/glassfish/domains/domain1/config/domain.xml"

	# verify that running from controller install directory
	[[ -f "$domainxml" ]] || { warn "unable to find $domainxml. Please run from controller install directory. Disabling $FN monitor."; return 1; }
	local pattern='^[[:digit:]]+$'
	local listen1port=$(get_dmnxml_listen_port http-listener-1)
	[[ "$listen1port" =~ $pattern ]] || listen1port=""	# ensure valid numeric else empty
	local listen2port=$(get_dmnxml_listen_port http-listener-2)
	[[ "$listen2port" =~ $pattern ]] || listen2port=""	# ensure valid numeric else empty


	( while true ; do
		sleep 1
		(( $(date +%s) % 30 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		local lp1 lp2
		if [[ -n "${listen1port:-}" ]] ; then
			eval $(awk 'BEGIN { print "declare -a vals1=(port='$listen1port'" } NF ==2 { print $2"="$1; tot+=$1 } END {print "TOTAL="tot")"}' <<< "$(netstat -ant | fgrep :$listen1port |awk '{print $6}' | sort | uniq -c )")
		else
			vals1="NO_http-listener-1_configured"
		fi
		if [[ -n "${listen2port:-}" ]] ; then
			eval $(awk 'BEGIN { print "declare -a vals2=(port='$listen2port'" } NF ==2 { print $2"="$1; tot+=$1 } END {print "TOTAL="tot")"}' <<< "$(netstat -ant | fgrep :$listen2port |awk '{print $6}' | sort | uniq -c )")
		else
			vals2="NO_http-listener-2_configured"
		fi
		echo -e "$(IFS=,; echo "${vals1[*]}" ),\t$(date +'%FT%T')" >> $LOGF
		echo -e "$(IFS=,; echo "${vals2[*]}" ),\t$(date +'%FT%T')" >> $LOGF
	done ) &
}

# output NUMA stats for memory pool sizes across nodes. When lowest order memory pool
# is too small for request this leads to entire process being swapped.
# /proc/vmstat entries for NUMA - hoping to find a proxy for processor cache invalidation
# in these
function numa_buddyrefs {
	local FN=numabuddyrefs
	local LOGF=$(mk_logname $FN)

	type numastat &> /dev/null || { warn "unable to find numastat command. Install with yum install numactl. Disabling $FN monitor."; return 1; }

	( while true ; do
		sleep 1
		(( $(date +%s) % 61 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		{ echo "datetime: $(date +'%FT%T')"; echo "#section buddyinfo:"; cat /proc/buddyinfo; echo
		  echo "#section procvmstat:"; { cat /proc/vmstat | fgrep -i numa; }; echo
		  echo "#section numastat:"; numastat; echo; } >> $LOGF
	done ) & 
}

# output of numastat java mysql - beware that this call actually stops the processes
# whilst stats are assembled. Doing this frequently will affect controller operation!
# polling once per 10 mins as sufficiently rare to avoid adverse consequences.
function numa_stat {
	local FN=numastat
	local LOGF=$(mk_logname $FN)

	type numastat &> /dev/null || { warn "unable to find numastat command. Install with yum install numactl. Disabling $FN monitor."; return 1; }

	( while true ; do
		sleep 1
		(( $(date +%s) % 601 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		{ echo "datetime: $(date +'%FT%T')"; numastat java mysql 2> /dev/null; echo; } >> $LOGF
	done ) & 
}

# incremental parse of MySQL slow.log - starts afresh each time monX is started
# Tries hard to parse potentially huge backlog in low/light-weight manner with
# initial config running at 400 input blocks then 10second pause
function slowlog {
	local FN=slowlog
	local LOGF=$(mk_logname $FN)

	# verify that running from controller install directory
        [[ -f ./db/db.cnf ]] || { warn "unable to find ./db/db.cnf. Please run from controller install directory. Disabling $FN monitor."; return 1; }
	local slowlogf=$(awk -F= '$1 == "slow_query_log_file" {print $2}' ./db/db.cnf)
	[[ -f "$slowlogf" ]] || { warn "unable to find MySQL slow.log file within ./db/db.cnf. Disabling $FN monitor."; return 1; }
	type perl &> /dev/null || { warn "unable to find perl command. Install with yum install perl. Disabling $FN monitor."; return 1; }
	type awk &> /dev/null || { warn "unable to find awk command. Install with yum install gawk. Disabling $FN monitor."; return 1; }
	type dd &> /dev/null || { warn "unable to find dd command. Install with yum install coreutils. Disabling $FN monitor."; return 1; }

	local bytesread=0 latestbyte=0 
	local pattern='^[[:digit:]]+$'
	( while true ; do
		sleep 1
		(( $(date +%s) % 421 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0

		latestbyte=$(awk '{print $5}' <<< "$(ls -l $slowlogf)")
		if [[ "$latestbyte" =~ $pattern ]] ; then		# ensure valid numeric file size
			(( $bytesread != "$latestbyte" )) || continue	# nothing to do yet
			if (( $latestbyte < $bytesread )) ; then	# quick'n'dirty has file been rotated check
				bytesread=0
			fi
#			parse_slowlog < <(dd bs=1 skip=$bytesread count=$(($latestbyte-$bytesread)) if=$slowlogf) >> $LOGF
			dd bs=1 skip=$bytesread count=$(($latestbyte-$bytesread)) if=$slowlogf 2>/dev/null | parse_slowlog >> $LOGF
		else
			echo "$(date +'%FT%T')	Bad slowlog[$slowlogf] filesize[$latestbyte]" >> $LOGF
		fi
		bytesread=$latestbyte
	done ) & 
}

# Bash 3.2 does not have associative arrays. It still is common. This addresses that.
# Based on single input string create 2 indexed arrays and 2 sets of variables with common prefix.
# For example:  setup_assoc_array monitor "(i=run_iostat v=run_vmstat d=run_dbtest)"
# creates:
# monitor_LAB=(i v d)
# monitor_VAL=(run_iostat run_vmstat run_dbtest)
# monitor_LAB_i=run_iostat monitor_LAB_v=run_vmstat monitor_LAB_d=run_dbtest
# monitor_VAL_run_iostat=i monitor_VAL_run_vmstat=v monitor_VAL_run_dbtest=d)
function setup_assoc_array {
   declare name=$1; shift
   declare -a arr="$@"
   declare -a lab=(${arr[*]%%=*})		# left side of first '='
   declare -a val=(${arr[*]#*=})		# right side of first '='

   eval "${name}_LAB=(${lab[@]})"		# indirect array assignment
   eval "${name}_VAL=(${val[@]})"
   local i j=0
   for i in $(seq 1 ${#lab[*]}) ; do
      printf -v "${name}_LAB_${lab[j]}" %s "${val[j]}"		# indirect assignment
      printf -v "${name}_VAL_${val[j]}" %s "${lab[j++]}"	# indirect assignment
   done
}
# destroy associative "array" created earlier with setup_assoc_array by:
#   destroy_assoc_array monitor
function destroy_assoc_array {
   declare name=$1 

   for i in $(eval 'echo ${!'"${name}_LAB"'*}') ; do unset $i; done
   for i in $(eval 'echo ${!'"${name}_VAL"'*}') ; do unset $i; done
}

###########################
# Main body
###########################

setup_assoc_array monitor "(i=run_iostat v=run_vmstat d=run_dbtest dv=run_dbvars f=run_fdcount m=run_memsize p=port_count n1=numa_buddyrefs n2=numa_stat sl=slowlog)"

declare OPTIONS=$(IFS=,; echo "${monitor_LAB[*]}")			# list of current options
declare USAGESTR="Usage: 
$PROGNAME [-t <ticket_number>]
	[-n]	Do not try to persist MySQL password if none available
	[-m <one of more of $OPTIONS to monitor>]
	[-x <one or more of $OPTIONS to NOT monitor>]
	[-S <4d to stop after 4 days. Can use one of h,d,w,m durations for hours,days,weeks,month>]
Where
$(IFS=$'\n';paste <(echo "${monitor_LAB[*]}") <(echo "${monitor_VAL[*]}"))"
default=1
DEADLINE=2000000000							# always stop by Tue May 17 20:33:20 PDT 2033
while getopts ":t:m:x:S:n" OPT ; do
	case $OPT in
		t  ) 	TICKETNM=$OPTARG
			;;
		m  ) 	unset mons; declare -a mons			# just these monitors
			default=0					# no longer default choices
			IFS=, read -a mons <<< "$OPTARG"
			for i in ${!to_monitor_*} ; do unset $i; done	# empty existing
			for i in ${mons[*]}; do
			        n="monitor_LAB_$i"
			  	if [[ -z "${!n}" ]]; then
			   		warn "include: unknown monitor key '$i'...ignoring"
					continue
			   	fi
			   	eval 'to_monitor_'"$i=${!n}"
			done
			;;
		x  ) 	unset mon; declare -a mons			# exclude these monitors
			default=0					# no longer default choices
			IFS=, read -a mons <<< "$OPTARG"
			for i in ${!to_monitor_*} ; do unset $i; done	# empty existing
		     	for i in ${monitor_LAB[*]}; do
				n="monitor_LAB_$i"
		     		eval 'to_monitor_'"$i=${!n}"	# copy all
		     	done
		     	for i in "${mons[@]}"; do 
			        n="monitor_LAB_$i"
			   	if [[ -z "${!n}" ]]; then
			   		warn "exclude: unknown monitor key '$i'...ignoring"
					continue
			   	fi
		           	unset 'to_monitor_'$i			# delete this monitor
		     	done
		        ;;
		S  )	declare pattern='^([[:digit:]]+)(h|d|w|m)$'
			[[ $OPTARG =~ $pattern ]] || err "$USAGESTR"
			declare number=${BASH_REMATCH[1]} unit=${BASH_REMATCH[2]}
			case $unit in
				h ) increment=$(( $number * 3600 )) ;;
				d ) increment=$(( $number * 86400 )) ;;
				w ) increment=$(( $number * 604800 )) ;;
				m ) increment=$(( $number * 2592000 )) ;; # assuming 30 day month
			esac
			DEADLINE=$(( $STARTTM + $increment ))
			;;
	        n  )    DONT_SAVE_PASSWD=1
			;;
		:  ) 	echo "$0: option '$OPTARG' requires a value" 1>&2
		     	err "$USAGESTR"
			;;
		\? ) 	err "$USAGESTR"
			;;
	esac
done
shift $(( $OPTIND - 1 ))

# check for and persist MYSQL root password - unless forbidden
if [[ -z "$DONT_SAVE_PASSWD" ]] ; then
	persist_mysql_passwd
fi

if [[ -z "${!to_monitor_*}" ]] ; then		# no monitors found
	if (( $default == 1 )) ; then		# assume all monitors wanted
     		for i in ${monitor_LAB[*]}; do
			n="monitor_LAB_$i"
     			eval 'to_monitor_'"$i=${!n}"	# copy all
     		done
	else					# nothing useful added or all excluded
		err "no valid monitors remain!"
	fi
fi

if [[ -z $TICKETNM ]] ; then
   	TICKETNM=XXXXX
   	warn "setting ticket number in log file name to $TICKETNM"
fi

# clean up any previous .pid files & processes for same mon<VERSION> script
[[ -n "$(ls ${LOGDIR}/${STEMNAME}.pid 2>/dev/null)" ]] && kill -9 $(cat ${LOGDIR}/${STEMNAME}.pid) 2> /dev/null
rm -f ${LOGDIR}/${STEMNAME}.pid 2> /dev/null

for i in ${!to_monitor_*}; do
	${!i}			# run monitor (assumes will background itself)
done
echo -$$ > ${LOGDIR}/${STEMNAME}.pid	# all sub-processes are in same process group

echo "kill monitors with \"kill -9 "$(cat ${LOGDIR}/${STEMNAME}.pid)"\""
