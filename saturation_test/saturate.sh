#!/bin/bash

#
# saturate a controller's metric ingest facility and report what that metric per min value is that causes saturation
#
# Assumes:
#   Robb Kane's SDK dummy agent from https://github.com/Appdynamics/Metric_Saturation_Test) 
#     Light foot print and easy to replicate to high conurrency levels
#
#								ran		08-Sep-2019

APPD_ROOT=/tempo
SDK_ROOT=/opt/appdynamics-cpp-sdk
SAT_AGENT_ROOT=/home/appdyn/Metric_Saturation_Test

#CONTROLLER_AK=e90c659e-3296-4a52-b1e9-b78ce789a6ca
#CONTROLLER_AK=0528c52b-e0b3-4a61-b301-f7be53b15b86
#CONTROLLER_AK=a6980e0c-8d33-4e53-8d53-4b7c262c7652
#CONTROLLER_AK=f9462928-45cf-4c05-8a81-2a181705bb45
CONTROLLER_AK=96260239-fce6-40b7-805f-3c6aa32c03dc
CONTROLLER_PORT=(8090 8091)
CONTROLLER_HOST=lab2
OA_APP_NAME=saturation_test1
LOCAL_APP_NAME=Metric_Saturation_Test_App
METRICS_PER_NODE=4000
NODES_PER_AGENT=10

SLEEP_MINS=12
SLEEP_TIME=$(( $SLEEP_MINS * 60 ))
BASE_SLEEP_MINS=12
BASE_SLEEP_TIME=$(( $BASE_SLEEP_MINS * 60 ))

BASE_LOAD=3000000
INCREMENTAL_LOAD=200000
EXIT_LOAD=1000000000		# unlikely to ever be reached

LAST_BUT_ONE_RATE=0
LAST_RATE=0
CURRENT_RATE=0
CURRENT_LOAD=0
CURRENT_AGENTS=0

declare -a PIDS
USAGESTR="Usage: $0 [-h <controller host>]
	[-p <controller port>]	# can be comma separated list - no spaces
	[-k <controller access_key>]
	[-b <base load in metrics per minute>]
	[-i <incremental load added per sleep_mins in metrics per minute>]
	[-s <sleep mins>]	# time between any increases in metric/min load to allow controller ingest to stabilise
	[-S <base sleep mins>]	# time after initial load and before any increment loads are applied
	[-X <max load>]		# complete 2 sleep periods and then exit script if this load is ever reached
	[-m <metrics per node>]
	[-n <nodes per agent>]
	[-C <controller install dir>
	[-d ]			# drop Application first"

trap "remove_load" EXIT

#  err "some message" [optional return code]
function err {
   local exitcode=${2:-1}                               # default to exit 1
   local c=($(caller 0))                                        # who called me?
   local r="${c[2]} (f=${c[1]},l=${c[0]})"                       # where in code?

   echo "$(date +'%FT%T')|ERROR| $r failed: $1" 1>&2

   exit $exitcode
}
function warn {
   echo "$(date +'%FT%T')|WARN| $1" 1>&2
}
function info {
   echo "$(date +'%FT%T')|INFO| $1" 1>&2
}

# quick and easy eay to check there is a live controller at end of supplied credentials
function verify_controller_access {
	local http_retc=$(curl -s -o /dev/null -w "%{http_code}\n" --user singularity-agent@customer1:$CONTROLLER_AK "http://$CONTROLLER_HOST:${CONTROLLER_PORT[0]}/controller/rest/applications/?output=JSON" 2>&1)
	(( $http_retc == 200 )) || { warn "verify_controller_access failed. Found '$http_retc'"; return 1; }
}

# make curl call and either return actual text else fixed literal 'CURL_FAILED'
function call_curl {
	(( $# >= 1 )) || err "Usage: ${FUNCNAME[0]} <curl args>"
	local curl_resp text retc

	for i in 1 2 3 ; do
		curl_resp=$(curl -m 4 -s -w "%{http_code}" "$@" 2>&1)
		retc=$?
		if (( $retc != 0 )) ; then
			(( $retc == 28 )) && continue || { echo "curl failed: $curl_resp" ; return $retc; }
		fi
		if [[ ${curl_resp: -3:1} == 2 ]] ; then		# all 2xx codes are SUCCESS
			text=${curl_resp:0: -3}
			break
		else
			text=CURL_FAILED
			continue
		fi
	done

	echo "$text"
	[[ "$text" == "CURL_FAILED" ]] && return 1 || return 0
}

# eventually Application accumulates too many nodes and then controller will reject further node registrations.
# Dropping the Application solves that - if permissions permit
# PROBLEM:
# it transpires that the controller internal code for deleting all the Application artifacts runs asynchronously
# to this call. Currently know of no way to make it synchronous. Source code in:
# controller/controller-beans/src/main/java/com/singularity/ee/controller/beans/model/ApplicationManagerBean.java
# server.log label ID: ID000504 <-- then look for log messages past start time saying:
# ID000504 Completed purging of ApplicationPurgeInfo ...
function drop_application {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <application name>"
	local app_name=$1 u="admin" a=customer1 cred app_id text pattern='^[[:digit:]]+$'
	local controller="http://$CONTROLLER_HOST:${CONTROLLER_PORT[0]}"

	if [[ -n "$LPSat" ]] ; then
		cred="$u@$a:$LPSat"
	else
		warn "local password not within LPsat variable...skipping ${FUNCNAME[0]} $@"
		return
	fi

	# get Application ID for subsequent delete 
	text=$(call_curl --user $cred ${controller}'/controller/rest/applications?output=JSON') || err "${FUNCNAME[0]}: get applications failed: $text"
	[[ "$text" != "CURL_FAILED" ]] || { warn "curl <list apps> failed... skipping ${FUNCNAME[0]}" ; return; }
	app_id=$(jq -r '.[] | select(.name == "'$app_name'") | .id' <<< "$text") || err "${FUNCNAME[0]}: JSON parse failed: $app_id"
	[[ $app_id =~ $pattern ]] || { warn "invalid Application_id='$app_id'... skipping ${FUNCNAME[0]}"; return; }

	# credential into controller
	text=$(call_curl --user $cred -c cookie.appd ${controller}'/controller/auth?action=login') || err "${FUNCNAME[0]}: OAuth login failed: $text"
	[[ "$text" != "CURL_FAILED" ]] || { warn "curl <credential> failed... skipping"; return; }
	X_CSRF_TOKEN=$(awk '$0 ~ /X-CSRF-TOKEN/ {print $NF}' cookie.appd)
	[[ -n "$X_CSRF_TOKEN" ]] || { warn "authentication failed...skipping ${FUNCNAME[0]}"; return; }
	X_CSRF_TOKEN_HEADER="`if [ -n "$X_CSRF_TOKEN" ]; then echo "X-CSRF-TOKEN:$X_CSRF_TOKEN"; else echo ''; fi`"

	# drop 
	text=$(call_curl -i -v -b cookie.appd -H "$X_CSRF_TOKEN_HEADER" -X POST ${controller}'/controller/restui/allApplications/deleteApplication' -H 'Content-Type: application/json;charset=UTF-8' --data-binary $app_id)
	[[ "$text" != "CURL_FAILED" ]] || { warn "curl <drop appname> failed... skipping"; return; }

	# drop Application API is asynchronous. But we need to wait until it's deleted everything.
	# Chatting with Maks B suggests waiting for MySQL to remove entry for application.id==<app_id> && application.name==<app_name>
	while [[ -n "$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< 'select id from controller.application where id='\'$app_id\'' and name like '\'${app_name}%\')" ]] ; do
		sleep 10
	done
	sleep 300		# vague guess based on earlier drop times
	echo "Application: $app_name dropped"
}

# Cause extra metrics per min to be sent to same controller. 
# First parameter is in units of metrics per min to increase controller load by. Function will
# determine smallest multiple of $metrics_per_agent that provide required new load.
# Call as:
#  load_controller 3000000
function load_controller {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <extra metric per min load rate>"
	local pattern='^[[:digit:]]+$'
	local new_rate=$1 i  startsecs endsecs port metrics_per_agent

	[[ $new_rate =~ $pattern ]] || err "${FUNCNAME[0]} needs numeric arg. Found '$1'"
	metrics_per_agent=$(( $METRICS_PER_NODE * $NODES_PER_AGENT ))
	local concurrency=$(( (($new_rate-1) / $metrics_per_agent) + 1 ))
	info "adding $new_rate metrics/min load via $concurrency new SDK agents"
	for i in $(seq 1 $concurrency) ; do
		# run for 2 days max (2880 mins) and send to customer1 account
		port=${CONTROLLER_PORT[$i % ${#CONTROLLER_PORT[*]}]}	# spread load across N server ports to lessen TIME_WAIT outbound socket limit
		( LD_LIBRARY_PATH=$SDK_ROOT/lib $SAT_AGENT_ROOT/saturationtest $CONTROLLER_HOST $port $CONTROLLER_AK customer1 2880 $METRICS_PER_NODE $NODES_PER_AGENT &>/dev/null ) &
		PIDS+=($!)
		(( $i % 20 == 0 )) && sleep 5
	done
	CURRENT_AGENTS=$(( CURRENT_AGENTS + concurrency ))
	CURRENT_LOAD=$(( CURRENT_LOAD + new_rate ))
	info "$CURRENT_LOAD current total load from $CURRENT_AGENTS agents...will take time for all agents to be sending"
}

# Stop all added controller load. Will leave untouched controller metric load arriving from any other
# source e.g. its internal Java agent.
function remove_load {
	local i

	for i in ${PIDS[*]} ; do
		kill -9 $i
	done
}

# helper function to print out ts_min given number of minutes in past
function get_ts_min {
	local pattern='^[[:digit:]]+$'
	local minsago=$1
	(( $# == 1 )) && [[ $minsago =~ $pattern ]] || err "Usage: ${FUNCNAME[0]} <integer number of mins ago>" 
	echo $(( ($(date +%s) / 60) - $minsago ))
}

# helper function to get metrics per min rate as of N mins ago
function get_metrics_per_min {
	local pattern='^[[:digit:]]+$'
	local minsago=$1
	(( $# == 1 )) && [[ $minsago =~ $pattern ]] || err "Usage: ${FUNCNAME[0]} <integer number of mins ago>"

	local ts_min=$( get_ts_min $minsago ) || err "${FUNCNAME[0]}:get_ts_min call failed: $ts_min"
# 	fetching count from local/secondary returns low values when replication is lagging
#	local curr_rate=$($APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select count(*) as count from metricdata_min where ts_min='$ts_min' ")
#
	local curr_rate=$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select count(*) as count from metricdata_min where ts_min='$ts_min' ")

	[[ $curr_rate =~ $pattern ]] || err "${FUNCNAME[0]}: invalid metric arrival rate ($curr_rate). Giving up"
	echo $curr_rate
}

# Encapsulate logic for determining when controller's ingest rate is saturated.
# Currently assume best indicator of controller's metric per minute ingest being saturated is:
# - number of metrics inserted into metricdata_min 5 mins ago does not grow for two test periods in a row (2*$SLEEP_MINS)
#   HA/mysqlclient.sh -r,-s <<< "select count(*) as count from metricdata_min where ts_min='$(( ($(date +%s) / 60) - 5 ))' " 
#   This is because we need to leave it a few mins (assume 5mins) for all metrics for that minute to have been written and
#   the controller will need some time (assume 12mins) to stabilise its ingestion of higher metric loads.
# For example, saturated if three contiguous reported rates are:
#  1000000 1000000 1000000
#  1000000 9999998 9999999
function do_sat1 {
	local minsago=8
	local ts_min=$( get_ts_min $minsago ) || err "${FUNCNAME[0]}:get_ts_min call failed: $ts_min"
	local curr_rate=$( get_metrics_per_min $minsago ) || err "${FUNCNAME[0]}:get_metrics_per_min call failed: $curr_rate"

	info "metrics per min at ts_min=$ts_min = $curr_rate"
	LAST_BUT_ONE_RATE=$LAST_RATE
	LAST_RATE=$CURRENT_RATE
	CURRENT_RATE=$curr_rate

	if (( LAST_BUT_ONE_RATE >= LAST_RATE && LAST_BUT_ONE_RATE >= CURRENT_RATE )) ; then
		info "concluding controller ingest saturated: LAST_BUT_ONE_RATE=$LAST_BUT_ONE_RATE LAST_RATE=$LAST_RATE CURRENT_RATE=$CURRENT_RATE"
		return 0
	else
		return 1
	fi
}
# Instead of taking 3 rates at SLEEP_TIME apart, use metrics ingest rates for 3 contiguous minutes.
# Healthy ingest should always be monotonically increasing to reflect the applied workload.
function do_sat2 {
	local minsago=8
	local current_rate=$( get_metrics_per_min $minsago ) || err "${FUNCNAME[0]}:get_metrics_per_min call failed: $current_rate"
	local last_rate=$( get_metrics_per_min $(( $minsago + 1 )) ) || err "${FUNCNAME[0]}:get_metrics_per_min 2 call failed: $last_rate"
	local last_but_one_rate=$( get_metrics_per_min $(( $minsago + 2 )) ) || err "${FUNCNAME[0]}:get_metrics_per_min 3 call failed: $last_but_one_rate"
	local ts_min=$( get_ts_min $minsago ) || err "${FUNCNAME[0]}:get_ts_min call failed: $ts_min"

	info "metrics per min at ts_min=$ts_min = $current_rate"

	if (( last_but_one_rate > last_rate && last_but_one_rate > current_rate )) ; then
		info "concluding controller ingest saturated: LAST_BUT_ONE_RATE=$last_but_one_rate LAST_RATE=$last_rate current_rate=$current_rate"
		return 0
	else
		return 1
	fi
}

# modified getpw (from HA Toolkit) that behaves like a function rather than 
# modifying its first parameter
function getpw { 
        (( $# == 0 )) || err "Usage: ${FUNCNAME[0]}"
        local pwch inpw1 inpw2=' ' prompt; 
        
        ref=$1 
        while [[ "$inpw1" != "$inpw2" ]] ; do
                prompt="Enter OA password: "
                inpw1=''
                while IFS= read -p "$prompt" -r -s -n1 pwch ; do 
                        if [[ -z "$pwch" ]]; then 
                                [[ -t 0 ]] && echo > /dev/tty
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
                                [[ -t 0 ]] && echo > /dev/tty
                                break 
                        else 
                                prompt='*'
                                inpw2+=$pwch 
                        fi 
                done 
        
                [[ "$inpw1" == "$inpw2" ]] || echo "passwords unequal. Retry..." 1>&2
        done
	(( ${#inpw1} > 0 )) || err "empty password not permitted"

	echo "$inpw1"
}

# Have discovered from Prasanth R that the only reliable way to learn of dropped metrics is from the
# metric reported via Glassfish's Java agent: 
# Application Infrastructure Performance|App Server|Custom Metrics|Relay|MySQL|Buffer Full|default
# Hence will watch that for an increase above a previous level.
# ASSUMPTIONS:
# - fixed Application name
# - URL comes from metric browser UI, right click, Copy REST URL
#   - modified above URL to output in JSON instead of default XML *and* changed duration-in-mins value
function do_sat3 {
	local drop_scan_mins=$SLEEP_MINS
	local URL='https://oa.saas.appdynamics.com/controller/rest/applications/'$OA_APP_NAME'/metric-data?metric-path=Application%20Infrastructure%20Performance%7CApp%20Server%7CCustom%20Metrics%7CRelay%7CMySQL%7CBuffer%20Full%7Cdefault&time-range-type=BEFORE_NOW&duration-in-mins='$drop_scan_mins'&output=JSON'
	local metrics_dropped u=rob.navarro a=appdynamics cred
	local minsago=0 retc
	local ts_min=$( get_ts_min $minsago ) || err "${FUNCNAME[0]}:get_ts_min call failed: $ts_min"

	if [[ -n "$PSat" ]] ; then
		cred="$u@$a:$PSat"
	else
		warn "OA password not within Psat variable...exiting ${FUNCNAME[0]} $@"
		exit 1
	fi

	metrics_dropped=$(call_curl --user $cred "$URL") || { retc=$?; warn "${FUNCNAME[0]}: get OA metrics curl failed: $metrics_dropped [retc=$retc]"; return 1; }
	[[ "$metrics_dropped" != "CURL_FAILED" ]] || { warn "${FUNCNAME[0]}: curl <get buffer full metrics> failed... failing"; return 1; }
	metrics_dropped=$(awk -F: '$1 ~ /sum/ {gsub(/[^[:digit:]]/,"",$2); print $2; exit}' <<< "${metrics_dropped}") || err "${FUNCNAME[0]}: awk call failed: $metrics_dropped"
	metrics_dropped=${metrics_dropped:-0}
	LAST_RATE=$CURRENT_RATE
	CURRENT_RATE=$metrics_dropped

	info "number dropped metrics in ${drop_scan_mins}mins up to ts_min=$ts_min = $metrics_dropped"

	if (( CURRENT_RATE > 0 )) ; then
		info "concluding controller ingest saturated: previous metrics dropped=$LAST_RATE ; current metrics dropped=$CURRENT_RATE"
		return 0
	else
		return 1
	fi

}

function saturated {
#	do_sat1
#	do_sat2
	do_sat3
}

###########################################################################################################
# Main body
###########################################################################################################
EARGS="$*"		# save copy of original command line
while getopts ":h:p:k:b:i:s:m:n:S:X:C:d" OPT ; do
	case $OPT in
		d )     if type jq &>/dev/null ; then
				drop_application $LOCAL_APP_NAME || warn "unable to drop Application: $LOCAL_APP_NAME"
			else
				warn "need to install package: jq ... skipping Application drop"
			fi
			;;
		h )	CONTROLLER_HOST=$OPTARG
			;;
		p )	pattern='^[[:digit:]]+(,[[:digit:]]+)*$'
			[[ $OPTARG =~ $pattern ]] || err "$USAGESTR"
			IFS=, read -a CONTROLLER_PORT <<< "$OPTARG"
			;;
		k )     CONTROLLER_AK=$OPTARG
			;;
		b )	pattern='^[[:digit:]]+$'
			[[ $OPTARG =~ $pattern ]] || err "$USAGESTR"
			BASE_LOAD=$OPTARG
			;;
		i )	pattern='^[[:digit:]]+$'
			[[ $OPTARG =~ $pattern ]] || err "$USAGESTR"
			INCREMENTAL_LOAD=$OPTARG
			;;
		s )	pattern='^[[:digit:]]+$'
			[[ $OPTARG =~ $pattern ]] || err "$USAGESTR"
			SLEEP_MINS=$OPTARG
			SLEEP_TIME=$(( $SLEEP_MINS * 60 ))
			;;
		S )	pattern='^[[:digit:]]+$'
			[[ $OPTARG =~ $pattern ]] || err "$USAGESTR"
			BASE_SLEEP_MINS=$OPTARG
			BASE_SLEEP_TIME=$(( $BASE_SLEEP_MINS * 60 ))
			;;
		m )     pattern='^[[:digit:]]+$'
			[[ $OPTARG =~ $pattern ]] || err "$USAGESTR"
			METRICS_PER_NODE=$OPTARG
			;;
		n )     pattern='^[[:digit:]]+$'
			[[ $OPTARG =~ $pattern ]] || err "$USAGESTR"
			NODES_PER_AGENT=$OPTARG
			;;
		X )	pattern='^[[:digit:]]+$'
			[[ $OPTARG =~ $pattern ]] || err "$USAGESTR"
			EXIT_LOAD=$OPTARG
			;;
		C )	[[ -f "$OPTARG"/db/db.cnf ]] || err "Invalid APPD_ROOT directory: $OPTARG"$'\n'"$USAGESTR"
			APPD_ROOT=$OPTARG
			;;
		: )	warn "$0: option '$OPTARG' requires a value"
			err "$USAGESTR"
			;;
		\?)	err "$USAGESTR"
			;;
	esac
done
shift $(( $OPTIND - 1 ))
rm -f /tmp/sat.out /tmp/appd/*

MBS=$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='metrics.buffer.size'")
#ACMRL=$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='application.custom.metric.registration.limit'")
#AMRL=$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='application.metric.registration.limit'")
#CMRL=$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='controller.metric.registration.limit'")
#MRL=$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='metric.registration.limit'")
SWE=$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='dis.metrics.stream-writer.enabled'")
SWT=$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='dis.metrics.stream-writer.threads'")
SWB=$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='dis.metrics.stream-writer.batchsize'")
WTC=$(ssh $CONTROLLER_HOST $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='write.thread.count'")
info "starting saturate run with:
comand line: $EARGS
CONTROLLER_AK=$CONTROLLER_AK
CONTROLLER_PORT=$(IFS=,;echo "${CONTROLLER_PORT[*]}")
CONTROLLER_HOST=$CONTROLLER_HOST
METRICS_PER_NODE=$METRICS_PER_NODE
NODES_PER_AGENT=$NODES_PER_AGENT
BASE_LOAD=$BASE_LOAD
INCREMENTAL_LOAD=$INCREMENTAL_LOAD
SLEEP_MINS=$SLEEP_MINS
BASE_SLEEP_MINS=$BASE_SLEEP_MINS
EXIT_LOAD=$EXIT_LOAD
metrics.buffer.size=$MBS
dis.metrics.stream-writer.enabled=${SWE:-false}
dis.metrics.stream-writer.threads=${SWT:-NULL}
dis.metrics.stream-writer.batchsize=${SWB:-NULL}
write.thread.count=${WTC:-NULL}"

verify_controller_access || err "invalid controller hostname, port and access_key"

# assume controller can cope with 3000000 metrics per minute, so start measuring there
saturated && exit 0
load_controller $BASE_LOAD
sleep $BASE_SLEEP_TIME		# let controller workload stabilise

while ! saturated ; do
	if (( CURRENT_LOAD >= EXIT_LOAD )) ; then
		info "breached EXIT_LOAD with $CURRENT_LOAD so will maintain current load for $(( 2 * SLEEP_TIME )) seconds and then exit"
		sleep $(( 2 * SLEEP_TIME ))
		break
	fi
	load_controller $INCREMENTAL_LOAD
	sleep $SLEEP_TIME
done

# clean up running agents - done via trap of EXIT
