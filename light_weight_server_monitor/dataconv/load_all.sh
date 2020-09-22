#!/bin/bash

#
# simplify the loading of all available monitors into OpenTSDB
#
# NOTES:
# - Initially will simply re-use same openTSDB "metric" to save disk space - this currently means deleting all existing data prior to loading new
#
# Design goals:
# - easy to load all
# - clearly shows any load errors and whether all loaded successfully
# - monitor loads are atomic - via some method maybe just delete all and redo minus the failing load
# - any failing monitor loads will, after some rollback, be followed by remaining monitor loads
#
#								ran 15-Sep-2020

EMPTY=false
EXIT_CODE=0
TSDBHOST=localhost
TSDBPORT=4242
METRIC=test1.1m.avg
DATACONV=~/github/controllertools/light_weight_server_monitor/dataconv
PROGNAME=${0##*/}
LOADIDFILE=/tmp/${PROGNAME}.loadid
TSDB=~/opentsdb/opentsdb/build/tsdb
USAGESTR="Usage: $PROGNAME -d <data dir1>,<d2>,<d3> 	# load all monitor data therein - comma separated directories
	[-e]						# empty openTSDB of data for $METRIC
	[-m	<mon1>,<mon2>]				# chosen monitors to load - comma separated
	[-c	<dataconv directory>]			# where the conversion tools live
"
declare -A MONS=(
  	       [iostat]="perl iostat_reformat.pl -c"
	       [vmstat]="bash vmstat_to_csv.sh"
	       [dbtest]=""				# not converted to CSV yet
	       [dbvars]="perl dbvars_to_csv.pl"
	      [fdcount]="bash fdcount_to_csv.sh"
	      [memsize]="perl memsize_to_csv.pl"
	    [conxcount]="perl conxcount_to_csv.pl"
	[numabuddyrefs]="perl numabuddyrefs_to_csv.pl"
	     [numastat]=""				# not converted to CSV yet
	      [slowlog]="perl slowlog_to_csv.pl"
	      [statics]=""				# never converted to CSV
	      [gfpools]="perl gfpools_to_csv.pl"
	       [procio]=""				# not converted to CSV yet
)
CHOSEN_MONS=()
FAILEDMONS=()
EMPTY_MONS=()

#  err "some message" [optional return code]
function err {
   local exitcode=${2:-1}                               # default to exit 1
   local c=($(caller 0))                                        # who called me?
   local r="${c[2]} (f=${c[1]},l=${c[0]})"                       # where in code?

   echo "ERROR: $r failed: $1" 1>&2

   (( exitcode > 0 )) && exit $exitcode
}

function warn {
   echo "WARN: $1" 1>&2
}

function info {
   echo "INFO: $1" 1>&2
}

function cleanup {
        rm -rf $TDIR &>/dev/null
}

function call_curl {
        (( $# >= 1 )) || err "Usage: ${FUNCNAME[0]} <curl args>"
        local curl_resp text retc

        [[ "$DEBUG" ]] && info "$(date +%FT%T): curl called with: $@"
        curl_resp=$(curl -m 4 -s -w "%{http_code}" "$@" 2>&1) || { retc=$?; warn "curl $@ failed: $curl_resp ($retc)"; return $retc; }
        if [[ ${curl_resp: -3:1} == 2 ]] ; then         # all 2xx codes are SUCCESS
                text=${curl_resp:0: $((${#curl_resp}-3))}                       # patch to run on MacOS Bash - that is too old
        else
                text=CURL_FAILED
        fi
        [[ "$text" == "CURL_FAILED" ]] && return 1 || { [[ -n "$text" ]] && echo "$text"; return 0; }
}

function get_all_metrics {
	(( $# == 2 )) || err "Usage: ${FUNCNAME[0]} <openTSDB host> <openTSDB port>"
	local host=$1 port=$2 ret

	ret=$(call_curl $host:$port/api/suggest'?type=metrics&max=200') || return 1
	jq -r '.[]' <<< "$ret"
}

# fail quickly if issues with connecting to openTSDB
function open_tsdb_running {
	(( $# == 2 )) || err "Usage: ${FUNCNAME[0]} <openTSDB host> <openTSDB port>"
	local host=$1 port=$2 ret

	ret=$(get_all_metrics "$host" "$port") || return 1
	# check if expected metric is currently defined
	fgrep -wq "$METRIC" <<< "$ret" || { warn "openTSDB on $host:$port does not contain metric $METRIC...giving up"; return 1; }
}

# output space separated list of monitor names that can be expected to have data for CSV conversion
# ASSUMES:
# - global associatve array MONS
# - global indexed array CHOSEN_MONS - overrides default list of all monitors within MONS
function available_monitors {
	(( $# == 0 )) || err "Usage: ${FUNCNAME[0]}"
	local m
	local -a mons

	(( ${#MONS[*]} > 0 )) || { warn "empty monitor array found - a bug!"; return 1; }
	(( ${#CHOSEN_MONS[*]} > 0 )) && mons=(${CHOSEN_MONS[*]}) || mons=(${!MONS[*]})

	for m in ${mons[*]}; do
		[[ -n "${MONS[$m]}" ]] && echo "$m"
	done
}

function delete_data {
	(( $# == 4 )) || err "Usage: ${FUNCNAME[0]} <metric> <openTSDB host> <openTSDB port> <TSDB>"
	local metric=$1 host=$2 port=$3 tsdb=$4 m errc=0

	errc=0
	for m in $(get_all_metrics "$host" "$port"); do
		[[ "$m" == "$metric" ]] || continue
		info "emptying data from openTSDB for $m metric..."
		$tsdb scan --delete 1970/01/01-00:00:00 min $m &>/dev/null || errc=1
	done
	if (( errc == 0 )); then
		# reset the loadid to keep cardinality small and openTSDB happier
		echo 0 > $LOADIDFILE || { warn "unable to write to $LOADIDFILE...giving up"; return 1; }
		return 0 
	else
		return 1
	fi
}

# encapsulate the way monX output files are identified given a LOADDIR and monitor name
function list_mon_outputs {
	(( $# == 2 )) || err "Usage: ${FUNCNAME[0]} <monitor> <loaddir vname>"
	local mon=$1 loaddir="$2[@]" d f

	for d in "${!loaddir}" ; do
		for f in $(ls -1 "$d"/*_${mon}_*[0-9].txt 2>/dev/null); do
			[[ -f "$f" ]] && echo "$f"
		done 
	done
}

# has monitor data been provided or not for current monitor?
# ASSUMES:
# - LOADDIR parameter is just the *name* of the array variable - will be indirectly referenced later
function exists_data {
	(( $# == 2 )) || err "Usage: ${FUNCNAME[0]} <monitor> <loaddir vname>"
	local mon=$1 loaddir=$2 
	local -a files

	files=($(list_mon_outputs "$mon" "$loaddir"))
	(( ${#files[*]} > 0 )) && return 0 || return 1
}

# helper function to get a useful hostname from monX data file that looks like:
# 214903_iostat_abcdef000003700.intranet.mycompany.com_1593031296.txt
function get_host {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <monX filename>"
	local fname=$1 thost fhost

	thost=${fname%_*}	# strip trailing _1593031296.txt
	fhost=${thost##*_}	# strip leading 214903_iostat_
	echo ${fhost%%.*}	# strip trailing .intranet.mycompany.com
}

# helper function to return a low cardinality but unique value per openTSDB monitor load that can be used to wipe out
# all rows marked with that label within openTSDB. When openTSDB is emptied this can reset back to zero.
function get_loadid {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <LOADIDFILE>"
	local loadidfile=$1 val pattern='^[[:digit:]]+$'

	val=$(<$loadidfile) || { err "unable to read contents of $loadidfile" 0; return 1; }
	[[ -n "$val" ]] || { err "empty $loadidfile" 0; return 1; }
	[[ $val =~ $pattern ]] || { err "invalid contents within $loadidfile" 0; return 1; }
	echo "$(( val+1 ))" > $loadidfile || { err "unable to update $loadidfile" 0; return 1; }
	echo "L$val"
}

function remove_data {
	(( $# == 3 )) || err "Usage: ${FUNCNAME[0]} <METRIC> <LOADID> <TSDB>"
	local metric=$1 loadid=$2 tsdb=$3

	$tsdb scan --delete 1970/01/01-00:00:00 min $metric loadid="$loadid" &>/dev/null
	if (( $? != 0 )); then
		warn "unable to delete openTSDB data for $metric metric with loadid=$loadid"
		return 1
	fi
}

# either fully load data for a given monitor or fail to load a single row for that monitor
# ASSUMES:
# - global associatve array MONS
# - LOADDIR parameter is just the name of the array variable - will be indirectly referenced later
# 
function load_data {
	(( $# == 6 )) || err "Usage: ${FUNCNAME[0]} <monitor name> <loaddir vname> <METRIC> <TSDBHOST> <TSDBPORT> <DATACONV>"
	local mon=$1 loaddir=$2 metric=$3 tsdbhost=$4 tsdbport=$5 dataconv=$6 
	local start_secs end_secs tcmd cmd txt loadid
	local -a files=($(list_mon_outputs "$mon" "$loaddir"))

	[[ -n "$mon" ]] || err "empty monitor arg"
	[[ -n "$loaddir" ]] || err "empty loaddir arg"
	[[ -n "$metric" ]] || err "empty metric arg"
	[[ -n "$tsdbhost" ]] ||	err "empty tsdbhost arg"
	[[ -n "$tsdbport" ]] || err "empty tsdbport arg"
	[[ -n "$dataconv" ]] || err "empty dataconv arg"
	host=$(get_host ${files[0]}) || return 1
	[[ -n "$host" ]] || { warn "empty hostname returned from get_host()"; return 1; }
	tcmd=${MONS[$mon]}
	cmd="${tcmd%% *} ${dataconv}/${tcmd#* }"		# insert correct path to conversion tools
	[[ -n "$cmd" ]] || { warn "unexpected empty conversion command for $mon monitor"; return 1; }

	start_secs=$(date +%s)
	loadid=$(get_loadid "$LOADIDFILE") || return 1
	info "starting load for $mon..."
	(set -o pipefail; $cmd < <(cat ${files[*]}) | perl ${dataconv}/csv_to_tsdb.pl -tz America/Los_Angeles -m $metric -h $host -L "$loadid" | pv | nc -w 15 $TSDBHOST $TSDBPORT) 
	if (( $? == 0 )); then
		end_secs=$(date +%s)
		info "successfully loaded data for $mon monitor ($((end_secs-start_secs)) sec)"
	else
		warn "load of $mon monitor data failed."$'\n'"cleaning up its data remnants..."
		remove_data "$metric" "$loadid" "$TSDB" || warn "cleanup for $mon monitor failed. Suggest manual clean of entire openTSDB and then re-load"
		return 1
	fi
}

# helper function to check whether 1st arg arrayname contains 2nd arg value or not
# Makes use of interesting variable dereference trick referred in:
# https://stackoverflow.com/questions/16461656/how-to-pass-array-as-an-argument-to-a-function-in-bash
# Call as:
#  in_array my_array XYZ || echo not found
function in_array {
	(( $# == 2 )) || err "Usage: ${FUNCNAME[0]} <array name> <value to check>"
        local arr="$1[@]" value="$2" i
        for i in ${!arr} ; do
                [[ "$i" == "$value" ]] && return 0
        done
        return 1
}


###########################
# Main body
###########################
type curl &>/dev/null || err "curl must be installed"
type jq &>/dev/null || err "jq must be installed"
type perl &>/dev/null || err "perl must be installed"
type pv &>/dev/null || err "pv must be installed"
[[ -f "$TSDB" ]] || err "unable to find openTSDB at $TSDB"
[[ -w "$LOADIDFILE" ]] || echo 0 > $LOADIDFILE || err "unable to initialise. Failed to write to $LOADIDFILE"

while getopts ":d:eDm:c:" OPT ; do
        case $OPT in
                d  ) unset tLOADDIR; declare -a tLOADDIR
			IFS=, read -a tLOADDIR <<< "$OPTARG"
			for i in "${tLOADDIR[@]}"; do
				[[ -d "$i" ]] && LOADDIR+=("$i") || warn "ignoring invalid directory: $i"
			done
			(( ${#LOADDIR[*]} > 0 )) || err "no valid -d directories"$'\n'"$USAGESTR"
                        ;;
                e  ) EMPTY=true
                        ;;
                m  ) unset tMONS iMONS; declare -a tMONS iMONS
			IFS=, read -a tMONS <<< "$OPTARG"
			iMONS=(${!MONS[*]})						# permissible monitor names
			for i in ${tMONS[*]}; do
				in_array iMONS "$i" && CHOSEN_MONS+=($i)
			done
			unset tMONS iMONS
			(( ${#CHOSEN_MONS[*]} > 0 )) || CHOSEN_MONS=(${MONS[*]})	# assume all required
                        ;;
                D  ) DEBUG=true
                        ;;
		c  ) [[ -d "$OPTARG" ]] || err "invalid directory for -c"$'\n'"$USAGESTR"
			DATACONV=$OPTARG
			;;
                :  ) echo "$0: option '$OPTARG' requires a value" 1>&2
                     err "$USAGESTR"
                        ;;
                \? ) err "$USAGESTR"
                        ;;
        esac
done
shift $(( $OPTIND - 1 ))
"$EMPTY" || [[ -n "$LOADDIR" ]] || err "at least one of -e or -d required"$'\n'"$USAGESTR"

open_tsdb_running "$TSDBHOST" "$TSDBPORT"|| err "openTSDB not reachable at $TSDBHOST:$TSDBPORT"

if "$EMPTY" ; then
	delete_data "$METRIC" "$TSDBHOST" "$TSDBPORT" "$TSDB" || err "unable to empty openTSDB of any prior data for metric: $METRIC"
	[[ -n "$LOADDIR" ]] || exit 0
fi

AVAILABLE_MONS=($(available_monitors)) || exit 1

for m in ${AVAILABLE_MONS[*]}; do
	exists_data "$m" "LOADDIR" || { EMPTY_MONS+=($m); warn "no data found for $m monitor...skipping"; continue; }	# skip if no data for this monitor
	if load_data "$m" "LOADDIR" "$METRIC" "$TSDBHOST" "$TSDBPORT" "$DATACONV"; then
		LOADED_MONS+=($m)
	else
		FAILED_MONS+=($m)
		warn "failed to load $m monitor data...skipping"
	fi
done

if (( ${#EMPTY_MONS[*]} > 0 )); then
	info "no data for monitors: ${EMPTY_MONS[*]} (${#EMPTY_MONS[*]})"
fi
if (( ${#FAILED_MONS[*]} > 0 )); then
	warn "failed to load monitors: ${FAILED_MONS[*]} (${#FAILED_MONS[*]})"
	EXIT_CODE=1
fi

if (( ${#LOADED_MONS[*]} > 0 )); then
	(( ${#AVAILABLE_MONS[*]} == ${#LOADED_MONS[*]} )) && PREF="all " || PREF=""
	info "${PREF}monitors loaded SUCCESSFULLY: ${LOADED_MONS[*]} (${#LOADED_MONS[*]})"
else
	warn "zero monitors loaded !"
	EXIT_CODE=1
fi

exit $EXIT_CODE
