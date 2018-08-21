#!/bin/bash

# kick off light monitoring of current server - endlessly or for fixed period
#
# Logs process IDs to $LOGDIR/{iostat,vmstat,dbtest}.pid for easier killing 
# but saves only the PIDs from the last startup. Running multiple
# copies of this script concurrently will only save one set of PIDs
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

function mk_logname {
	(( $# == 1 )) || err "mk_logname: needs function name arg"
	local FN=${1:-MISSING_FUNCNAME}
	echo "${LOGDIR}/${TICKETNM}_${FN}_${HOST}_${STARTTM}.txt"
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
	( iostat -tzmx $DEVS $interval $count > $LOGF & echo $! > ${LOGDIR}/${FN}_${STEMNAME}.pid )
}

function run_vmstat {
	local FN=vmstat
	local LOGF=$(mk_logname $FN)

	# verify that required programs are installed
	type awk vmstat &> /dev/null || { warn "unable to find awk and vmstat commands. Disabling $FN monitor."; return 1; }

	local interval=30
	local count=$(( ($DEADLINE - $STARTTM)/$interval ))
	# need to flush STDOUT to ensure unbuffered & continuous output via pipe and redirection
	( awk 'BEGIN {cmd="vmstat '"$interval $count"'"; while (( cmd | getline ) > 0) {print $0" "strftime("%Y-%m-%dT%T"); fflush()}}' > $LOGF & echo $! > ${LOGDIR}/${FN}_${STEMNAME}.pid )
}

function run_dbtest {
	local FN=dbtest
	local LOGF=$(mk_logname $FN)

	# verify that running from controller install directory
	[[ -f ./HA/mysqlclient.sh ]] || { warn "unable to find ./HA/mysqlclient.sh. Please ensure HA Toolkit is installed and run from controller install directory. Disabling $FN monitor."; return 1; }

	(
	while true ; do
		sleep 0.9
		(( $(date +%s) % 60 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		timeout 59s bash -c 'V=$(HA/mysqlclient.sh -c -t <<\EOT
drop table if exists mq_watchdog_test2_table;
create table mq_watchdog_test2_table (i int);
insert into mq_watchdog_test2_table values (1);
select count(*) from mq_watchdog_test2_table;
drop table mq_watchdog_test2_table;
EOT
); R=$?; echo $(date +'%FT%T') \"$V\" retc=$R >> '"$LOGF"
		R=$? 
		(( $R == 124 )) && echo $(date +'%FT%T') \"DB test timed out\" retc=$R >> $LOGF
		sleep 0.1
	done & echo $! > ${LOGDIR}/${FN}_${STEMNAME}.pid )
}

function run_dbvars {
	local FN=dbvars
	local LOGF=$(mk_logname $FN)
	declare -a vars 

	# verify that running from controller install directory
	[[ -f ./HA/mysqlclient.sh ]] || { warn "unable to find ./HA/mysqlclient.sh. Please ensure HA Toolkit is installed and run from controller install directory. Disabling $FN monitor."; return 1; }
	# verify that required programs are installed
	type awk &> /dev/null || { warn "unable to find awk command. Disabling $FN monitor."; return 1; }

	(
	while true ; do
		sleep 0.9
		(( $(date +%s) % 60 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		timeout 59s bash -c ' 
eval $(awk '\''NF==2 {print "array_"$1"="$2}'\'' < <(HA/mysqlclient.sh -c -t <<< "show global status") )
declare -a mv=(Queries Aborted_clients Aborted_connects Connections Created_tmp_tables Created_tmp_disk_tables)
eval $(awk '\''BEGIN { print "declare -a vars=( " } { print $1"=${array_"$1"} " } END { print ")" }'\'' <<< "$(printf '\''%s\n'\'' ${mv[*]})" )
IFS=, ; echo -e "${vars[*]}\t$(date +'%FT%T')" >> '"$LOGF"
		R=$? 
		(( $R == 124 )) && echo $(date +'%FT%T') \"DB vars check timed out\" retc=$R >> $LOGF
		sleep 0.1
	done & echo $! > ${LOGDIR}/${FN}_${STEMNAME}.pid )
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
	done & echo $! > ${LOGDIR}/${FN}_${STEMNAME}.pid )
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
	done & echo $! > ${LOGDIR}/${FN}_${STEMNAME}.pid )
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
	done & echo $! > ${LOGDIR}/${FN}_${STEMNAME}.pid )
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

setup_assoc_array monitor "(i=run_iostat v=run_vmstat d=run_dbtest dv=run_dbvars f=run_fdcount m=run_memsize p=port_count)"

declare OPTIONS=$(IFS=,; echo "${monitor_LAB[*]}")			# list of current options
declare USAGESTR="Usage: $PROGNAME [-t <ticket_number>]
	[-m <one of more of $OPTIONS to monitor>]
	[-x <one or more of $OPTIONS to NOT monitor>]
	[-S <4d to stop after 4 days. Can use one of h,d,w,m durations for hours,days,weeks,month>]
Where
$(IFS=$'\n';paste <(echo "${monitor_LAB[*]}") <(echo "${monitor_VAL[*]}"))"
default=1
DEADLINE=2000000000							# always stop by Tue May 17 20:33:20 PDT 2033
while getopts ":t:m:x:S:" OPT ; do
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
		:  ) 	echo "$0: option '$OPTARG' requires a value" 1>&2
		     	err "$USAGESTR"
			;;
		\? ) 	err "$USAGESTR"
			;;
	esac
done
shift $(( $OPTIND - 1 ))


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
[[ -n "$(ls ${LOGDIR}/*_${STEMNAME}.pid 2>/dev/null)" ]] && kill -9 $(cat ${LOGDIR}/*_${STEMNAME}.pid) 2> /dev/null
rm -f ${LOGDIR}/*_${STEMNAME}.pid 2> /dev/null

for i in ${!to_monitor_*}; do
	${!i}			# run monitor (assumes will background itself)
done

echo "kill monitors with \"kill -9 "$(cat ${LOGDIR}/*_${STEMNAME}.pid)"\""
