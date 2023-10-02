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
#
# removed/lessened dependency on Bash exported functions
#						ran 27-Feb-2019
#
# Added ability to stop in X minutes and configure custom
# path for perl
#						ran 12-Mar-2019
# 
# Added ability to monitor all listening Glassfish ports and
# upraded slowlog logic to match later external version
#						ran 25-Sep-2019
#
# Fixed DB monitor ability to run on all cluster nodes at same
# time. Look for specific block devices in monx.settings for iostat.
# Record slowly changing/static server configs.
#						ran 04-Apr-2020
#
# Added Glassfish monitor for thread and connection pools to
# help spot cases where pool wait times get large.
# Added ability for MySQL monitors to run whenever they can.
#						ran 29-Apr-2020
#
# Improved incoming Glassfish connection queue wait time estimate.
# Fixed occasional overcount within port_count.
#						ran 17-May-2020
#
# Minor improvements around finding commands in different environments
# and ensuring glassfish monitor does not trip over local file names.
#						ran 18-Jun-2020
#
# Modified memsize to include amount of swap space used by Glassfish
# and MySQL. 
#						ran 23-Jul-2020
#
# Added per process (MySQL & Glassfish) I/O monitor
#						ran 18-Aug-2020
#
# Significantly enhanced dbvars monitor to include all HA Toolkit
# metrics and others to help catch too-small log cases
#						ran 7-May-2021
#

PROGNAME=${0##*/}
STEMNAME=${PROGNAME%%.*}
STARTTM=$(date +%s)
TICKETNM=
HOST=$(hostname)
LOGDIR=/var/tmp
MLOGF=${LOGDIR}/monX.log
PERL=${PERL:-$(which perl)}			# allow override of executable if $PATH wrong
MONX_SETTINGS=${LOGDIR}/monx.settings

#  err "some message" [optional return code]
function err {
   local exitcode=${2:-1}                               # default to exit 1
   local c=($(caller 0))                                        # who called me?
   local r="${c[2]} (f=${c[1]},l=${c[0]})"                       # where in code?

   echo "ERROR: $r failed: $1" 1>&2
   echo "[#|$(date +'%FT%T')|ERROR|$r failed: $1|#]" >> $MLOGF

   exit $exitcode
}
function warn {
   echo "WARN: $1" 1>&2
   echo "[#|$(date +'%FT%T')|WARN|$1|#]" >> $MLOGF
}
function info {
   echo "INFO: $1" 1>&2
   echo "[#|$(date +'%FT%T')|INFO|$1|#]" >> $MLOGF
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
#export -f obf_ofa1

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
#export -f deobf_ofa1

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
#export -f obf_ofa2

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
#export -f deobf_ofa2

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
#export -f obfuscate

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
#export -f deobfuscate

# with help from:
# http://stackoverflow.com/questions/1923435/how-do-i-echo-stars-when-reading-password-with-read
function getpw { 
        (( $# >= 1 )) || err "Usage: ${FUNCNAME[0]} <variable name> [<optional prompt text>]"
        local pwch inpw1 inpw2=' ' prompt ptext
        
        ref=$1 
	[[ -n "$2" ]] && ptext=$2 || ptext="MySQL root"
	while [[ "$inpw1" != "$inpw2" ]] ; do
		prompt="Enter ${ptext} password: "
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

	# assign to variable whose name is 1st parameter
	printf -v "$ref" %s "$inpw1"	# assign passwd to parameter variable
}
#export -f getpw

# helper function to allow separate setting of passwd from command line.
# Use this to persist an obfuscated version of the MySQL passwd to disk.
function save_mysql_passwd {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <APPD_ROOT>"

	local thisfn=${FUNCNAME[0]} APPD_ROOT=$1 obf pw
	[[ -d $1 ]] || err "$thisfn: \"$1\" is not APPD_ROOT"
	local rootpw_obf="$APPD_ROOT/db/.rootpw.obf"

	getpw pw || exit 1		# updates pw variable
	export dbpasswd=$pw
	obf=$(obfuscate "$pw") || exit 1
	echo $obf > $rootpw_obf || err "$thisfn: failed to save obfuscated passwd to $rootpw_obf"
	chmod 600 $rootpw_obf || warn "$thisfn: failed to make $rootpw_obf readonly"
}
#export -f save_mysql_passwd

# helper function to persist obfuscated Glassfish asadmin password
function save_asadmin_passwd {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <APPD_ROOT>"

	local thisfn=${FUNCNAME[0]} APPD_ROOT=$1 pw obf
	[[ -d $1 ]] || err "$thisfn: \"$1\" is not APPD_ROOT"
	local asadmin_obf="$APPD_ROOT/.asadmin.obf"

	getpw pw "Glassfish admin" || exit 1	# updates pw variable
	export gfpasswd=$pw
	obf=$(obfuscate "$pw") || exit 1
	echo "$obf" > $asadmin_obf || err "$thisfn: failed to save obfuscated passwd to $asadmin_obf"
	chmod 600 $asadmin_obf || warn "$thisfn: failed to make $asadmin_obf readonly"
}
#export -f save_asadmin_passwd

###
# get MySQL root password in a variety of ways, in order:
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

	if [[ -z "$clear" && -n "$MYSQL_ROOT_PASSWD" ]] ; then
		clear=$MYSQL_ROOT_PASSWD
		echo $clear
	fi
	if [[ -z "$clear" && -s $rootpw && -r $rootpw ]] ; then 
		clear=$(<$rootpw)
		echo  $clear
	fi
	if [[ -z "$clear" && -s $rootpw_obf ]] ; then
		IFS=$' ' read -r otype obf < $rootpw_obf
		[[ -n "$otype" && -n "$obf" ]] || err "unable to read obfuscated passwd from $rootpw_obf"
		clear=$(deobfuscate $otype $obf)
		[[ -n "$clear" ]] || err "unable to deobfuscate passwd from $rootpw_obf" 2
		echo $clear
	fi
	if [[ -z "$clear" && -s $mysqlpw ]] ; then
	   	# sneaky way to get MySQL tool: mysql_config_editor to write its encrypted .mylogin.cnf
	   	# to a place that is guaranteed to exist. Some clients have no writeable user home 
	   	# directory !
	   	export MYSQL_TEST_LOGIN_FILE=$APPD_ROOT/db/.mylogin.cnf

		clear=$(awk -F= '$1 ~ "word" {print $2}' <<< "$($APPD_ROOT/db/bin/my_print_defaults -s client)")
		[[ -n "$clear" ]] || err "unable to get passwd from $mysqlpw" 3
		echo $clear
	fi
	if [[ -z "$clear" ]] ; then
		err "no password in MYSQL_ROOT_PASSWORD, db/.rootpw, db/.rootpw.obf or db/.mylogin.cnf please run save_mysql_passwd.sh" 3
	fi
}
#export -f get_mysql_passwd

# get Glassfish asadmin password in a variety of ways, in order:
# 1. $APPD_ROOT/setpwd.gf
# 2. $APPD_ROOT/.passwordfile
# 3. $APPD_ROOT/.asadmin.obf
function get_asadmin_passwd {
	(( $# == 0 )) || err "Usage: ${FUNCNAME[0]}"
	if [[ -z "$APPD_ROOT" ]] ; then
		[[ -f ./db/db.cnf ]] || err "unable to find ./db/db.cnf. Please run from controller install directory."
		export APPD_ROOT="$(pwd -P)"
	fi
	local clear obf otype 
	local asadmin_obf="$APPD_ROOT/.asadmin.obf" setpwd="$APPD_ROOT/setpwd.gf" pwdfile="$APPD_ROOT/.passwordfile"

	if [[ -z "$clear" && -s "$setpwd" && -r "$setpwd" ]] ; then
		clear=$(awk -F= '$1=="AS_ADMIN_NEWPASSWORD" {print $2}' $setpwd)
		[[ -n "$clear" ]] && echo "$clear" || warn "unable to read Glassfish admin password from $setpwd"
	fi
	if [[ -z "$clear" && -s "$pwdfile" && -r "$pwdfile" ]] ; then
		clear=$(awk -F= '$1=="AS_ADMIN_PASSWORD" {print $2}' $pwdfile)
		[[ -n "$clear" ]] && echo "$clear" || warn "unable to read Glassfish admin password from $pwdfile"
	fi
	if [[ -z "$clear" && -s "$asadmin_obf" && -r "$asadmin_obf" ]] ; then
		IFS=$' ' read -r otype obf < $asadmin_obf
		[[ -n "$otype" && -n "$obf" ]] || err "unable to read obfuscated passwd from $asadmin_obf"
		clear=$(deobfuscate $otype $obf)
		[[ -n "$clear" ]] && echo "$clear" || warn "unable to deobfuscate passwd from $asadmin_obf" 2
	fi
	if [[ -z "$clear" ]] ; then
		err "no Glassfish admin password found on disk" 3
	fi
}
#export -f get_asadmin_passwd

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

	if [[ -n "$dbpasswd" ]] ; then			# nothing to do ... just export & return
		export dbpasswd
		return 0
	fi

	# given no MySQL root password was found, now prompt user for it and persist to disk
	if [[ -x $APPD_ROOT/db/bin/mysql_config_editor ]] ; then
	   	# sneaky way to get MySQL tool: mysql_config_editor to write its encrypted .mylogin.cnf
	   	# to a place that is guaranteed to exist. Some clients have no writeable user home 
	   	# directory !
	   	export MYSQL_TEST_LOGIN_FILE=$APPD_ROOT/db/.mylogin.cnf

		# MySQL bug: https://bugs.mysql.com/bug.php?id=74691 that silently accepts less
		# characters than entered by user!
		# Note MySQL bug report shows delimiting single quote work-around
		# Note getpass source code: https://code.woboq.org/userspace/glibc/misc/getpass.c.html
		# shows stdin opened if no /dev/tty available. Will use this.
		# Work-around with:
		# - separate and reliable password collection into a variable
		# - use setsid to disconnect controlling TTY from sub-process
		# - use Here string to setsid with single quotes around variable
		getpw _XYZ
		$APPD_ROOT/db/bin/mysql_config_editor reset
		setsid bash -c "$APPD_ROOT/db/bin/mysql_config_editor set --user=root -p 2>/dev/null" <<< "'$_XYZ'"
	else
		save_mysql_passwd $APPD_ROOT
	fi
}
#export -f persist_mysql_passwd

function persist_asadmin_passwd {
	if [[ -z "$APPD_ROOT" ]] ; then
		[[ -f ./db/db.cnf ]] || err "unable to find ./db/db.cnf. Please run from controller install directory."
		export APPD_ROOT="$(pwd -P)"
	fi

	gfpasswd=$(get_asadmin_passwd 2> /dev/null)	# ignore return 1 and err msg if no passwd

	if [[ -n "$gfpasswd" ]]; then			# nothing more to do
		export gfpasswd
		return 0
	fi

	# given no Glassfish password was found on disk, now prompt user for it and then try to persist again
	save_asadmin_passwd $APPD_ROOT
}
#export -f persist_asadmin_passwd

function get_dbport {
	if [[ ! -f ./db/db.cnf ]] ; then
		err "unable to find ./db/db.cnf. Please run from controller install directory."
		return 1
	fi

	awk -F= '$1 =="port" {print $2}' ./db/db.cnf
}
#export -f get_dbport

# simple, sometimes unreliable, wrapper for MySQL client
# WARNINGS:
# - will not always work within sub-shell as some sites break Bash export of functions
#   instead use: setup_mysql_connect || return 1; timeout 3s bash -c './db/bin/mysql -A $DBPARAMS controller <<< ...'
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
#export -f mysqlclient

# Observed client that has locally disabled Bash exported functions entirely by corrupting the ENV 
# value for each function - likely an over reaction to Shellshock (see: https://dwheeler.com/essays/shellshock.html)
# Can work-around by observing only breaks bash -c '... mysqlclient...' function calls at the moment and
# so can split mysqlclient into set up function that creates all variables so that a simple call
# to ./db/bin/mysql -A $DBPARAMS controller will then suffice instead of function call.
# NOTE: cannot export Bash arrays either !
#
# ASSUMPTIONS:
# - must be idempotent i.e. can be run multiply without issue
function setup_mysql_connect {
	DBPORT=${DBPORT:-$(get_dbport)} || return 1
	DBPARAMS="--host=localhost --protocol=TCP --user=root --port=$DBPORT"
	APPD_ROOT=${APPD_ROOT:-"$(pwd -P)"}		# assumes directory checked earlier
	export MYSQL_TEST_LOGIN_FILE=${MYSQL_TEST_LOGIN_FILE:-$APPD_ROOT/db/.mylogin.cnf}
	if [[ ! -f $APPD_ROOT/db/.mylogin.cnf ]] ; then
		dbpasswd=${dbpasswd:-$(get_mysql_passwd 2> /dev/null)} || err "MySQL password not already persisted. Please re-run without -n parameter to do that"
		DBPARAMS+=" --password=$dbpasswd"
	fi
	export DBPARAMS
}
#export -f setup_mysql_connect
###################### End of embedded file: ../obfus_lib.sh


# unchanged lines 51-91 of github/controllertools/slowlogmetric.pl of Aug-2019 version
# Can change number of parse blocks and pause interval with optional parameters:
#   parse_slowlog 500 5  # 500 blocks read with 5 second pause thereafter
function parse_slowlog {
   $PERL -se '
use warnings;
#use strict;
# unchanged slowlogmetric.pl below
$/ = "# User\@Host: ";                  # read in blocks delimited by this string

my $insert_cmd1 = qr{LOAD DATA CONCURRENT LOCAL INFILE .dummy.txt. IGNORE INTO TABLE metricdata_min FIELDS};    # 2012 syntax
my $insert_cmd2 = qr{.. .. LOAD DATA CONCURRENT LOCAL INFILE .dummy.txt. IGNORE INTO TABLE metricdata_min FIELDS}; # 2012 syntax
my $insert_cmd3 = qr{INSERT IGNORE INTO metricdata_min\s+SELECT};       # 4.2 syntax
my $insert_cmd = qr/(?:$insert_cmd1)|(?:$insert_cmd2)|(?:$insert_cmd3)/;

select((select( STDOUT ), $|=1)[0]); 			# enable command buffering i.e. flush after each print
print "timestamp,buffer,query_tm,lock_tm,rows\n" if $csv_needed;

my $blocks_read = 0;
my $same_buff = 15; 		# assume all rows within 15 secs of each other to be in same buffer if buffer_num <= 4
my ($buffer_num, $lastsecs) = (0, 0);
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

      if ((abs($esecs - $lastsecs) <= 15) && $buffer_num < 4) {
         ++$buffer_num;         # measure time delay from first row in group hence no lastsecs update here
      } else {
         $buffer_num = 1;
         $lastsecs = $esecs;
      }

      if ($csv_needed) {
         print "$datetm,$buffer_num,$query_tm,$lock_tm,$rows_ex\n" if $query_tm > $thresh_secs;
      } else {
         print "$datetm\tbuffer=$buffer_num\tquery_tm=$query_tm\tlock_tm=$lock_tm\trows=$rows_ex\n" if $query_tm > $thresh_secs;
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
#export -f mk_logname

# check if MySQL credentials exist - but not if they work
function exist_mysql_creds {
	dbpasswd=$(get_mysql_passwd 2> /dev/null)
	if [[ -n "$dbpasswd" ]] ; then
		export dbpasswd
		return 0
	else
		return 1
	fi
}

# Return 0 if can get useful mysql client job, else 1.
# Does not assume functions are exported by Bash.
function check_db_connection {
	setup_mysql_connect || return 1			# ensure $DBPARAMS configured
	timeout 59s bash -c 'T=$(./db/bin/mysql -A $DBPARAMS controller <<< "select '\''YESCON'\''" 2>&1); [[ "$T" =~ YESCON$ ]] || { echo "$T" 1>&2; exit 123; }'
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

# check if asadmin credentials available - but not if they work
# Assigns GLOBAL: ASCREDS
function exist_asadmin_creds {
	gfpasswd=$(get_asadmin_passwd 2> /dev/null)
	if [[ -n "$gfpasswd" ]] ; then
		export gfpasswd
		return 0
	else
		return 1
	fi
}

# export ASADMIN,ASCREDS variables with sufficient params that subsequent call to asadmin works - as tested by check_asadmin_connection()
function setup_asadmin_connect {
        local cfile text retc

        exist_asadmin_creds && [[ -n "$gfpasswd" ]] || { warn "asadmin credentials unavailable"; return 1; }
        ASADMIN="./appserver/glassfish/bin/asadmin -t --host localhost --port 4848 --user admin --passwordfile="
	ASCREDS="AS_ADMIN_PASSWORD=$gfpasswd"
        export ASADMIN
        export ASCREDS

        # attempt to fetch current monitoring levels
        text=$(timeout 30s bash -c '$ASADMIN<( echo $ASCREDS ) get server.monitoring-service.module-monitoring-levels."*"' 2>&1)
        retc=$?
        (( $retc == 0 )) || { warn "${FUNCNAME[0]}: check monitor levels call failed, retc=$retc: $text"; return 1; }

        # can we stop early?
        [[ $(awk -F= '$1 ~ /http-service$/ { print $2 }' <<< "$text") == "HIGH" && $(awk -F= '$1 ~ /jdbc-connection-pool$/ { print $2 }' <<< "$text") == "HIGH" ]] && return 0

        # attempt to set required monitoring levels
        text=$(timeout 30s bash -c '$ASADMIN<( echo $ASCREDS ) set server.monitoring-service.module-monitoring-levels.http-service=HIGH' 2>&1)
        retc=$?
        (( $retc == 0 )) || { warn "${FUNCNAME[0]}: set monitor http-service=HIGH call failed, retc=$retc: $text"; return 1; }
        text=$(timeout 30s bash -c '$ASADMIN<( echo $ASCREDS ) set server.monitoring-service.module-monitoring-levels.jdbc-connection-pool=HIGH' 2>&1)
        retc=$?
        (( $retc == 0 )) || { warn "${FUNCNAME[0]}: set monitor jdbc-connection-pool=HIGH call failed, retc=$retc: $text"; return 1; }

        # attempt to fetch current monitoring levels
        text=$(timeout 30s bash -c '$ASADMIN<( echo $ASCREDS ) get server.monitoring-service.module-monitoring-levels."*"' 2>&1)
        retc=$?
        (( $retc == 0 )) || { warn "${FUNCNAME[0]}: check monitor levels call failed, retc=$retc: $text"; return 1; }
        [[ $(awk -F= '$1 ~ /http-service$/ { print $2 }' <<< "$text") == "HIGH" && $(awk -F= '$1 ~ /jdbc-connection-pool$/ { print $2 }' <<< "$text") == "HIGH" ]] || { warn "${FUNCNAME[0]}: unable to set asadmin monitor levels, retc=$retc"; return 1; }
}

# return 0 if can sucessfully call asadmin else 1
function check_asadmin_connection {
	local text

	setup_asadmin_connect || return 1		# ensure ASADMIN and ASCREDS defined
	text=$(timeout 30s bash -c '$ASADMIN<( echo $ASCREDS ) get server.monitoring-service.module-monitoring-levels."*"' 2>&1)
	if [[ $(awk -F. 'NR==1{print $1}' <<< "$text") == "server" ]] ; then
		return 0
	else
		return 1
	fi
}

# helper function to check whether 1st arg arrayname contains 2nd arg value or not
# Makes use of interesting variable dereference trick referred in:
# https://stackoverflow.com/questions/16461656/how-to-pass-array-as-an-argument-to-a-function-in-bash
# Call as:
#  in_array my_array XYZ || echo not found
function in_array {
	local arr="$1[@]" value="$2" i
	for i in ${!arr} ; do
		[[ "$i" == "$value" ]] && return 0
	done
	return 1
}

# Will start an endlessly running program to output to specific log file.
# PID saved to simplify killing when needed.
function run_iostat {
	local FN=iostat
	local LOGF=$(mk_logname $FN) 
	local DEVS allDevs=($(lsblk -dln | awk '{print $1}')) i monx_found=""

	# verify that required programs are installed
	type iostat &> /dev/null || { warn "unable to find sysstat package 'iostat'. Disabling iostat monitor."; return 1; }

	# look for customised devices that are to be monitored
	if [[ -n "$MONX_IOSTAT_DEVS" ]] ; then
		monx_found=1
	elif [[ -s "$MONX_SETTINGS" ]] ; then
		. $MONX_SETTINGS
		monx_found=1
	fi
	if [[ -n "$monx_found" ]] ; then
		for i in $MONX_IOSTAT_DEVS ; do
			in_array allDevs "$i" && DEVS+=($i)
		done
		(( ${#DEVS[*]} > 0 )) || DEVS=(${allDevs[*]})		# in case no valid inputs found
	else
		DEVS=$(lsblk -dln | awk '$1 ~ /^(sd)|(fi)|(nv)|(xv)|(em)/ {print $1}')
	fi

	local interval=60
	local count=$(( ($DEADLINE - $STARTTM)/$interval ))
	( export S_TIME_FORMAT=ISO; iostat -tzmx ${DEVS[@]} $interval $count > $LOGF ) &
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

# helper function for run_dbtest to build table name that will not affect replication health if:
# - table is replicated to other server
# - and both HA servers are running monX at same time
# Call as:
#  N=$(get_tab_name) 
function get_tab_name {
	local -a A
	local HS i pattern='^[[:xdigit:]]+$' slave_status tname

	HS=$(hostname | md5sum)
	HS=${HS%% *}
	[[ "$HS" =~ $pattern ]] || return 1

	# if replication configured then try to derive a tablename that will not be replicated
	setup_mysql_connect || return 1                 # ensure $DBPARAMS configured
	slave_status=$(timeout 59s bash -c './db/bin/mysql -A $DBPARAMS controller <<< "show slave status\G"')
	tname=$(for i in $(awk '$1=="Replicate_Wild_Ignore_Table:" { print gensub(/,/," ","g",$2) }' <<< "$slave_status"); do 
		[[ ${i%%.*} == "controller" ]] && echo ${i/\%/${HS}dbtest}
	done | head -1)

	# else create table name unique to current hostname
	if [[ -z "$tname" ]] ; then
		tname="controller.mq_${HS}dbtest"
	fi

	echo "$tname"
}

function run_dbtest {
	local FN=dbtest
	local LOGF=$(mk_logname $FN)
	local tabname

	# verify that running from controller install directory
	[[ -f ./db/db.cnf ]] || { warn "unable to find ./db/db.cnf. Please run from controller install directory. Disabling $FN monitor."; return 1; }
	exist_mysql_creds || { warn "MySQL root credentials unavailable. Disabling $FN monitor."; return 1; }

	( while true ; do
		sleep 0.95
		(( $(date +%s) % 60 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		if check_db_connection 2>> $MLOGF ; then
			if [[ -z "$tabname" ]] ; then
				tabname=$(get_tab_name)
				[[ -n "$tabname" ]] || { warn "unable to create temp table name. Disabling $FN monitor."; exit 1; }
			fi
		else
			sleep 300
			continue
		fi
		timeout 59s bash -c 'V=$(./db/bin/mysql -A $DBPARAMS controller <<< "
drop table if exists '"$tabname"';
create table '"$tabname"' (i int);
insert into '"$tabname"' values (1);
select count(*) from '"$tabname"';
drop table '"$tabname"';
" 2>&1); R=$?; echo $(date +'%FT%T') \"$V\" retc=$R >> '"$LOGF"
		R=$? 
		(( $R == 124 )) && echo $(date +'%FT%T') \"DB test timed out\" retc=$R >> $LOGF
	done ) &
}

# helper function for dbvars to output single CSV row from each compound DB status call
function parse_db_state {
	#
	# MySQL status is assessed each time period with the compound query (to get all measurements as close to timepoint as possible):
	#
	# select 'START SECTION 1';
	# show engine innodb status\G
	# select 'START SECTION 2';
	# show global status;
	# select 'START SECTION 3';
	# select max(time) as hiwat, count(*) as xcount from information_schema.processlist where command ='Query'\G
	# 
	# this compound output will have 3 levels of information:
	# - level 1 separates SQL commands
	# - levels 2 and 3 partition individual SQL commands e.g. show engine innodb status which has 2 level nested structure
	#
	# References:
	# https://www.percona.com/blog/2006/07/17/show-innodb-status-walk-through/
	# https://dev.mysql.com/doc/refman/5.7/en/information-schema-processlist-table.html
	#
	(( $# == 3 )) || err "Usage: ${FUNCNAME[0]} <timestamp> <awk_init_string> <firstcall 0 or 1>"
	local timestamp=$1 awk_init=$2 first_call=$3

	# be *SUPER* careful to not use single quotes below unless done consciously - watch comments!
	awk '
	BEGIN { '"$awk_init"' timestamp="'$timestamp'"; firstcall='$first_call' } 	# bring in constants from MySQL engine config and calling env
	$0 ~ /^START SECTION/ 				{ l1 = $3 }			# set level 1 section number

	# show engine innodb status\G
	l1 == 1 && /^FILE I\/O/				{ l2 = 1 }
	l1 == 1 && l2 == 1 && /reads.*writes.*fsyncs$/ 	{ reads = $1; writes = $5; syncs = $9 }	# different from HATK

	l1 == 1 && /^LOG/				{ l2 = 2 }
	l1 == 1 && l2 == 2 && /^Log sequence number/	{ logseq = $NF }
	l1 == 1 && l2 == 2 && /^Log flushed up to/	{ logflushed = $NF }
	l1 == 1 && l2 == 2 && /^Last checkpoint at/	{ logcheckpoint = $NF }
	l1 == 1 && l2 == 2 && /ding log fl.*kp writes$/	{ pendinglog = $1; pendingckpt = $5 }
	l1 == 1 && l2 == 2 && /log i\/o.*second$/	{ logio = $1 }			# different from HATK

	l1 == 1 && /^BUFFER POOL AND MEMORY/ 		{ l2 = 3 }
	l1 == 1 && l2 == 3 && /^Buffer pool size/	{ bufsz = $NF }
	l1 == 1 && l2 == 3 && /^Free buffers/		{ freebuf = $NF }
	l1 == 1 && l2 == 3 && /^Database pages/		{ dbpages = $NF }
	l1 == 1 && l2 == 3 && /^Old database pages/	{ olddbpages = $NF }
	l1 == 1 && l2 == 3 && /^Modified db pages/	{ dirty = $NF }
	l1 == 1 && l2 == 3 && /^Pending wr.*LRU.*flus/	{ pendLRU = gensub(/,/,"","g",$4); pendflush = gensub(/,/,"","g",$7); singlepg = $NF }

	l1 == 1 && /^INDIVIDUAL BUFFER POOL INFO/ 	{ l2 = 33 }			# ignored for now

	l1 == 1 && /^ROW OPERATIONS/			{ l2 = 4 }
	l1 == 1 && l2 == 4 && /^Number of rows.*read/	{ inserts = gensub(/,/,"","g",$5); 		# different from HATK
								updates = gensub(/,/,"","g",$7);	# different from HATK 
								deletes = gensub(/,/,"","g",$9); 	# different from HATK
								rowreads = $NF }			# different from HATK

	# show global status;
	l1 == 2 && /^Queries/				{ queries = $NF }
	l1 == 2 && /^Questions/				{ questions = $NF }
	l1 == 2 && /^Aborted_clients/			{ aclients = $NF }
	l1 == 2 && /^Aborted_connects/			{ aconnects = $NF }
	l1 == 2 && /^Connections/			{ connections = $NF }
	l1 == 2 && /^Created_tmp_tables/		{ ctmp_tabs = $NF }
	l1 == 2 && /^Created_tmp_disk_tables/		{ ctmp_disk_tabs = $NF }
	l1 == 2 && /^Threads_created/			{ cr_threads = $NF }
	l1 == 2 && /^Innodb_buffer_pool_reads/		{ bp_diskreads = $NF }
	l1 == 2 && /^Innodb_buffer_pool_wait_free/	{ bp_waits = $NF }
	l1 == 2 && /^Innodb_log_waits/			{ log_waits = $NF }
	l1 == 2 && /^Innodb_row_lock_waits/		{ row_lock_waits = $NF }
	l1 == 2 && /^Table_locks_waited/		{ tab_lock_waits = $NF }

	# select max(time) as hiwat, count(*) as xcount from information_schema.processlist where command = "Query"\G
	l1 == 3 && /hiwat/				{ max_qtime = $NF }
	l1 == 3 && /xcount/				{ xcount = $NF }

	END { 
		if (firstcall) { 				# emit CSV header once
			printf  "%s", "timestamp"		# output of date +%FT%T
			printf ",%s", "OS_file_reads"		# show engine innodb status->FILE I/O->"OS file reads"
			printf ",%s", "OS_file_writes"		# show engine innodb status->FILE I/O->"OS file writes"
			printf ",%s", "OS_fsyncs"		# show engine innodb status->FILE I/O->"OS fsyncs"

			printf ",%s", "Log_sequence_number"	# show engine innodb status->LOG->"Log sequence number"
			printf ",%s", "Log_flushed_up_to"	# show engine innodb status->LOG->"Log flushed up to"
			printf ",%s", "Log_unflushed_pct_buf"	# COMPUTED: 100*("Log sequence number"-"Log flushed up to")/val["innodb_log_buffer_size"]
			printf ",%s", "Last_checkpoint_at"	# show engine innodb status->LOG->"Last checkpoint at"
			printf ",%s", "checkpoint_age_pct_log"	# COMPUTED: 100*("Log sequence number"-"Last checkpoint at")/(val["innodb_log_file_size"] * val["innodb_log_files_in_group"])
			printf ",%s", "pending_log_flushes"	# show engine innodb status->LOG->"pending log flushes"
			printf ",%s", "pending_chkp_writes"	# show engine innodb status->LOG->"pending chkp writes"
			printf ",%s", "log_ios_done"		# show engine innodb status->LOG->"log i/os done"

			printf ",%s", "free_pct_bufpages"	# COMPUTED: 100*("Free buffers")/"Buffer pool size"
			printf ",%s", "Database_pages"		# show engine innodb status->BUFFER POOL AND MEMORY->"Database pages" (entire buffer pool)
			printf ",%s", "Old_database_pages"	# show engine innodb status->BUFFER POOL AND MEMORY->"Old database pages" (entire buffer pool)
			printf ",%s", "Modified_db_pages"	# show engine innodb status->BUFFER POOL AND MEMORY->"Modified db pages" (entire buffer pool)
			printf ",%s", "Pending_writes_LRU"	# show engine innodb status->BUFFER POOL AND MEMORY->"Pending writes: LRU" (entire buffer pool)
			printf ",%s", "Pending_writes_flush"	# show engine innodb status->BUFFER POOL AND MEMORY->"Pending writes: flush list" (entire buffer pool)
			printf ",%s", "Pending_writes_single"	# show engine innodb status->BUFFER POOL AND MEMORY->"Pending writes: single page" (entire buffer pool)

			printf ",%s", "rows_inserted"		# show engine innodb status->"ROW OPERATIONS"->"Number of rows inserted"
			printf ",%s", "rows_updated"		# show engine innodb status->"ROW OPERATIONS"->"Number of rows updated"
			printf ",%s", "rows_deleted"		# show engine innodb status->"ROW OPERATIONS"->"Number of rows deleted"
			printf ",%s", "rows_read"		# show engine innodb status->"ROW OPERATIONS"->"Number of rows read"

			printf ",%s", "Queries"				# show global status->Queries
			printf ",%s", "Questions"			# show global status->Questions
			printf ",%s", "Aborted_clients"			# show global status->Aborted_clients
			printf ",%s", "Aborted_connects"		# show global status->Aborted_connects
			printf ",%s", "Connections"			# show global status->Connections
			printf ",%s", "Created_tmp_tables"		# show global status->Created_tmp_tables
			printf ",%s", "Created_tmp_disk_tables"		# show global status->Created_tmp_disk_tables
			printf ",%s", "Threads_created"			# show global status->Threads_created
			printf ",%s", "Innodb_buffer_pool_reads"	# show global status->Innodb_buffer_pool_reads
			printf ",%s", "Innodb_buffer_pool_wait_free"	# show global status->Innodb_buffer_pool_wait_free
			printf ",%s", "Innodb_log_waits"		# show global status->Innodb_log_waits
			printf ",%s", "Innodb_row_lock_waits"		# show global status->Innodb_row_lock_waits
			printf ",%s", "Table_locks_waited"		# show global status->Table_locks_waited

			printf ",%s", "current_query_maxtime"		# hiwat from: select max(time) as hiwat, count(*) as xcount from information_schema.processlist where command ="Query"
			printf ",%s", "current_query_count"		# xcount from: select max(time) as hiwat, count(*) as xcount from information_schema.processlist where command ="Query"
			
			printf "\n"
		}
		printf  "%s", timestamp
		printf ",%s", reads
		printf ",%s", writes
		printf ",%s", syncs

		printf ",%s", logseq
		printf ",%s", logflushed
		printf ",%.1f", 100*(logseq - logflushed)/val["innodb_log_buffer_size"]
		printf ",%s", logcheckpoint
		printf ",%.1f", 100*(logseq - logcheckpoint)/(val["innodb_log_file_size"] * val["innodb_log_files_in_group"])
		printf ",%s", pendinglog
		printf ",%s", pendingckpt
		printf ",%s", logio

		printf ",%.1f", 100*freebuf/bufsz
		printf ",%s", dbpages
		printf ",%s", olddbpages
		printf ",%s", dirty
		printf ",%s", pendLRU
		printf ",%s", pendflush
		printf ",%s", singlepg

		printf ",%s", inserts
		printf ",%s", updates
		printf ",%s", deletes
		printf ",%s", rowreads

		printf ",%s", queries
		printf ",%s", questions
		printf ",%s", aclients
		printf ",%s", aconnects
		printf ",%s", connections
		printf ",%s", ctmp_tabs
		printf ",%s", ctmp_disk_tabs
		printf ",%s", cr_threads
		printf ",%s", bp_diskreads
		printf ",%s", bp_waits
		printf ",%s", log_waits
		printf ",%s", row_lock_waits
		printf ",%s", tab_lock_waits

		printf ",%s", max_qtime
		printf ",%s", xcount

		printf "\n"
	}
	'
}

function run_dbvars {
	local FN=dbvars
	local LOGF=$(mk_logname $FN)
	local svals awk_init M datetime
	local -i got_gvals=0 R first_output=1

	# verify that running from controller install directory
	[[ -f ./db/db.cnf ]] || { warn "unable to find ./db/db.cnf. Please run from controller install directory. Disabling $FN monitor."; return 1; }
	# verify that required programs are installed
	type awk &> /dev/null || { warn "unable to find awk command. Install with yum install gawk. Disabling $FN monitor."; return 1; }
	exist_mysql_creds || { warn "MySQL root credentials unavailable. Disabling $FN monitor."; return 1; }
	
	# name in status_val the MySQL "show global variables" values that are needed
	declare -a status_val=(innodb_log_file_size innodb_log_files_in_group innodb_log_buffer_size)

	( while true ; do
		sleep 0.95
		(( $(date +%s) % 60 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		check_db_connection 2> /dev/null || { sleep 300; got_gvals=0; continue; }	# retry after a bit

		# first time able to access DB fetch MySQL global variables - formatted as GAWK array assignments in a string 
		# e.g. 'val["innodb_log_file_size"]="12345";val["innodb_log_files_in_group"]="2"' 
		if (( got_gvals == 0 )); then
			M=$(timeout 30s bash -c './db/bin/mysql -s -A $DBPARAMS controller <<< "show global variables"' 2>&1)
			R=$?
			if (( $R == 0 )) && [[ -n "$M" ]] ; then
				# convert every global status row to a shell variable assignment - around 500-600
				eval $(awk '{k=$1;$1="";print "array_"k"=\""substr($0,2)"\""}' <<< "$M")
				# create an array of just required key=value text strings
				eval $(awk 'BEGIN { print "declare -a vars=( " } { print $1"=${array_"$1"} " } END { print ")" }' <<< "$(printf '%s\n' ${status_val[*]})")
				# create awk syntax for array assignment from vars shell array - ready for injection into subsequent awk
				awk_init=$(for i in "${vars[@]}"; do key=${i%%=*}; val=${i#*=}; printf %s "val[\"$key\"]=\"$val\";"; done)
			elif (( $R == 124 )) ; then
				echo "$(date +'%FT%T'),\"DB show global variables timed out\" retc=$R"$'\n' >> $LOGF
				continue
			else
				echo "$(date +'%FT%T'),\"DB show global variables call failed\" retc=$R:$M"$'\n' >> $LOGF
				continue
			fi
			got_gvals=1			# ensure not run again
		fi

		M=$(timeout 30s bash -c './db/bin/mysql -s -A $DBPARAMS controller <<< "select '\''START SECTION 1'\'';show engine innodb status\Gselect '\''START SECTION 2'\'';show global status;select '\''START SECTION 3'\'';select max(time) as hiwat, count(*) as xcount from information_schema.processlist where command ='\''Query'\''\G"' 2>&1)
		R=$?
#echo "$M" > /tmp/dbvars.$(date +%s)
		if (( $R == 0 )) && [[ -n "$M" ]] ; then
			datetime=$(date +%FT%T)
			parse_db_state "$datetime" "$awk_init" "$first_output" <<< "$M" >> $LOGF
			first_output=0
		elif (( $R == 124 )) ; then
			echo "$(date +'%FT%T'),\"get DB stats timed out\" retc=$R"$'\n' >> $LOGF
		else
			echo "$(date +'%FT%T'),\"get DB stats call failed\" retc=$R:$M"$'\n' >> $LOGF
		fi
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
		sleep 0.95
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

# helper function to return a suitably formatted subset of stats from /proc/[pid]/status for given [pid]
function proc_status {
	local pattern='^[[:digit:]]+$' pid=$1
	(( $# == 1 )) && [[ "$pid" =~ $pattern ]] || err "Usage: ${FUNCNAME[0]} <pid>"
	local text				# separate local definition permits capture of AWK failure on RHS of assignment
	text=$(awk '
		$1=="VmHWM:"	{ txt = (txt " ") sprintf("peak_m=%.0f", $2/1024) }
		$1=="VmRSS:"	{ txt = (txt " ") sprintf("rss_m=%.0f", $2/1024) }
		$1=="VmSwap:"	{ txt = (txt " ") sprintf("swap_m=%.0f", $2/1024) }
		$1=="Threads:"	{ txt = (txt " ") sprintf("threads=%d", $2) }
		END		{ print txt }' /proc/$pid/status) || return 1
	echo "$text"				# preserve leading space by quoting
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
		sleep 0.95
		(( $(date +%s) % 30 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		local mysqlpid=$(pgrep -f "[m]ysqld .*--port=$(awk -F= '$1 == "port" {print $2}' db/db.cnf)") 
		local gfpid=$(pgrep -f "[g]lassfish.jar .*-javaagent:")
		local sql gf txt datetime_m datetime_g
		datetime_m=$(date +%FT%T)
		if [[ -n "${mysqlpid:-}" ]] ; then
			txt="mysql"$(proc_status $mysqlpid 2>&1) && sql=$txt || sql="UNABLE_TO_READ_/proc/$mysqlpid/status [$txt]"
		else
			sql="NO_MYSQL_RUNNING"
		fi
		datetime_g=$(date +%FT%T)
		if [[ -n "${gfpid:-}" ]] ; then
			txt="gf"$(proc_status $gfpid 2>&1) && gf=$txt || gf="UNABLE_TO_READ_/proc/$mysqlpid/status [$txt]"
		else
			gf="NO_GLASSFISH_RUNNING"
		fi

		echo "$datetime_m "$sql$'\n'"$datetime_g "$gf >> $LOGF
	done ) & 
}

# helper function to scan domain.xml for all network-listener port numbers that are not disabled
# Call as:
#  P=$(get_dmnxml_all_listen_ports) || exit 1
#  if [[ -n "$P" ]] ; then
#     process $P
#  fi
function get_dmnxml_all_listen_ports {
        (( $# == 0 )) || err "Usage: ${FUNCNAME[0]}"
        local domainxml="./appserver/glassfish/domains/domain1/config/domain.xml"
        [[ -r "$domainxml" ]] || return 0

        awk -F= '$1 ~/content$/ { print $2 }' <<< "$(xmllint --shell $domainxml <<< 'xpath //config[@name="server-config"]/network-config/network-listeners/network-listener[not(@enabled) or @enabled="true"]/@port')"
}
#export -f get_dmnxml_all_listen_ports

# output number of connections for each of http-
function port_count {
	local FN=conxcount
	local LOGF=$(mk_logname $FN)
	local domainxml="./appserver/glassfish/domains/domain1/config/domain.xml" i tmp

	# verify that running from controller install directory
	[[ -f "$domainxml" ]] || { warn "unable to find $domainxml. Please run from controller install directory. Disabling $FN monitor."; return 1; }
	local pattern='^[[:digit:]]+$'

	local -a port=( $(get_dmnxml_all_listen_ports) )
        local -a arr_indices=( ${!ports[*]} )           # need index to delete array elements
        local pattern='^[[:digit:]]+$'
        for i in ${arr_indices[*]} ; do                 # ensure only numeric ports
                if [[ ! ${port[ $i ]} =~ $pattern ]] ; then
                        unset port[$i]
                fi
        done

        ( while true ; do
                sleep 0.95
                (( $(date +%s) % 30 == 0 )) || continue
                (( $(date +%s) < $DEADLINE )) || exit 0

                for i in ${port[*]} ; do
                        eval $(awk 'BEGIN { tot=0; print "declare -a vals=(port='$i'" } NF ==2 { print $2"="$1; tot+=$1 } END {print "TOTAL="tot")"}' <<< "$(netstat -ant |awk '$4 ~ /:'$i'$/ {print $6}' | sort | uniq -c )")
                        tmp="$(IFS=,; echo "${vals[*]}" )\t$(date +'%FT%T')"    # impossible to export array hence flatten first
			echo -e "$tmp" >> $LOGF
                done
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
		sleep 0.95
		(( $(date +%s) % 137 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		{ echo "datetime: $(date +'%FT%T')"; echo "#section buddyinfo:"; cat /proc/buddyinfo; echo
		  echo "#section procvmstat:"; { cat /proc/vmstat | fgrep -i numa; }; echo
		  echo "#section numastat:"; numastat -czmn; echo; } >> $LOGF
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
		sleep 0.95
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
	$PERL -version &> /dev/null || { warn "unable to find working perl command. Install with yum install perl or change PATH. Disabling $FN monitor."; return 1; }
	type awk &> /dev/null || { warn "unable to find awk command. Install with yum install gawk. Disabling $FN monitor."; return 1; }
	type dd &> /dev/null || { warn "unable to find dd command. Install with yum install coreutils. Disabling $FN monitor."; return 1; }

	local bytesread=0 latestbyte=0 
	local pattern='^[[:digit:]]+$'
	( while true ; do
		sleep 0.95
		(( $(date +%s) % 421 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0

		latestbyte=$(awk '{print $5}' <<< "$(ls -n $slowlogf)")
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

# try moderately hard to find named binary's full pathname and echo it and return 0 if found else return 1
function findprog {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <program to find full path of>"
	local prog=$1 comm
	if comm=$(type -p $prog 2>/dev/null) && [[ -n $comm ]] ; then 
		echo $comm
		return 0
	fi
	if comm=$(awk '{print $2}' <(whereis -b $prog)) && [[ -n $comm ]] ; then 
		echo $comm
		return 0
	fi 
	return 1
}

# one off collection of slowly changing server stats like CPU, RAM or various config files
function one_offs {
	local FN=statics
	local LOGF=$(mk_logname $FN)
	local C

	function bracket {
		echo "################################ $@ ################################"
	}

	[[ -f ./db/db.cnf ]] || { warn "unable to find ./db/db.cnf. Please run from controller install directory. Disabling $FN monitor."; return 1; }

	( while true ; do
		sleep 2
		{ echo "datetime: $(date +'%FT%T%:z')"
		  bracket "Appserver version"
		  if [[ -f "./appserver/glassfish/domains/domain1/applications/controller/controller-web_war/version.properties" ]] ; then
		  	echo "$(< ./appserver/glassfish/domains/domain1/applications/controller/controller-web_war/version.properties)"
		  elif [[ -f "./appserver/glassfish/domains/domain1/applications/controller/META-INF/MANIFEST.MF" ]] ; then
		  	echo "$(< ./appserver/glassfish/domains/domain1/applications/controller/META-INF/MANIFEST.MF)"
		  else
			echo "no AppD version manifest found"
		  fi
		  bracket "MySQL version"
		  C=$(findprog perl) && $C -lane '($v) = $_ =~ m/Distrib ([0-9.]+)/; print "$v"' <<< $(db/bin/mysql -V)
		  bracket "free -g"
		  C=$(findprog free) && $C -g
		  bracket "uname -a"
		  C=$(findprog uname) && $C -a
		  bracket "id"
		  C=$(findprog id) && $C
		  bracket "shell limits"
		  [[ -d /proc && -n "$BASHPID" ]] && cat /proc/$BASHPID/limits || ulimit -aS
		  bracket "lscpu"
		  C=$(findprog lscpu) && $C
		  bracket "lsblk -i"
		  C=$(findprog lsblk) && $C -i
		  bracket "df -PhT"
		  C=$(findprog df) && $C -PhT
		  bracket "df -Ph <MySQL datadir>"
		  C=$(findprog df) && $C -Ph $(awk -F= '$1=="datadir" {print $2}' db/db.cnf)
		  bracket "mount"
		  C=$(findprog mount) && $C
		  bracket "ifconfig -a"
		  C=$(findprog ifconfig) && $C -a
		  bracket "netstat -r"
		  C=$(findprog netstat) && $C -r
		  if [[ -d /sys/class ]] && C=$(findprog ethtool) && [[ -n $C ]] ; then
		  	bracket "NIC configs"
		  	for i in $(sort <<< $(ls -d /sys/class/net/*)); do [[ -s "$i/speed" ]] && [[ ${i##*/} != "lo" ]] && ethtool ${i##*/} 2>/dev/null || continue; done
		  fi
		  bracket "sysctl -a | fgrep dirty_"
		  C=$(findprog sysctl) && $C -a 2>/dev/null| fgrep dirty_
		  bracket "various kernel settings"
		  C=/proc/sys/vm/swappiness; 				[[ -f "$C" ]] && echo "$C: $(cat $C)"
		  C=/sys/kernel/mm/transparent_hugepage/enabled; 	[[ -f "$C" ]] && echo "$C: $(cat $C)"
		  C=/sys/kernel/mm/transparent_hugepage/defrag;  	[[ -f "$C" ]] && echo "$C: $(cat $C)"
		  C=/sys/kernel/mm/redhat_transparent_hugepage/enabled; [[ -f "$C" ]] && echo "$C: $(cat $C)"
		  C=/sys/kernel/mm/redhat_transparent_hugepage/defrag;  [[ -f "$C" ]] && echo "$C: $(cat $C)"
		  C=/proc/sys/kernel/numa_balancing;  			[[ -f "$C" ]] && echo "$C: $(cat $C)"
		  bracket "db.cnf"
		  C=$(<./db/db.cnf); echo "$C"				# solves missing trailing newline problem
		  bracket "domain.xml"
		  C=$(<./appserver/glassfish/domains/domain1/config/domain.xml); echo "$C"	# solves missing trailing newline problem
		  if check_db_connection 2>> $MLOGF ; then
		  	bracket "global_configuration"
			timeout 59s bash -c './db/bin/mysql -A $DBPARAMS controller <<< "select name,value from global_configuration"'
		  fi
		  echo; } >> $LOGF
		exit 0
	done ) & 
}

# helper function for gftools to convert Glassfish monitor output into smaller CSV style form
function parse_gf_mon {
	#
	# convert all currently useful Glassfish monitor output into CSV
	#
	# Once Glassfish http-service and connection-pool monitoring is enabled:
	#
	# ASADMIN="./appserver/glassfish/bin/asadmin -t --host localhost --port 4848 --user admin --passwordfile=$(pwd)/.passwordfile"
	# $ASADMIN get server.monitoring-service.module-monitoring-levels.*
	# $ASADMIN set server.monitoring-service.module-monitoring-levels.http-service=HIGH
	# $ASADMIN set server.monitoring-service.module-monitoring-levels.jdbc-connection-pool=HIGH
	#
	# input is assumed to be output of:
	# $ASADMIN get --monitor server.*
	#
	# https://javaee.github.io/glassfish/doc/5.0/administration-guide.pdf
	#
	(( $# == 2 )) || err "Usage: ${FUNCNAME[0]} $(date +%FT%T) <last_epochsecs,last_requestcount>"
	local TIMESTAMP=$1 arg2=$2 current_epoch last_epoch last_requestcount

	current_epoch=$(date +%s --date "$TIMESTAMP")
	if [[ -n "$arg2" ]] ; then
		last_epoch=${arg2%%,*} 
		last_requestcount=${arg2##*,}
	else
		last_epoch=0
		last_requestcount=0
	fi

	awk '
	$1 ~ /^server\.network\.[^.]+\.connection-queue\..+-count$/                     { split($1,cq,"."); ln[cq[3]]=1; connq[cq[3]"."cq[5]] = $3 }
	$1 ~ /^server\.network\.[^.]+\.thread-pool\..+-count$/                          { split($1,tp,"."); ln[cq[3]]=1; thrp[tp[3]"."tp[5]] = $3 }
	$1 ~ /^server\.http-service\.server\.request\.(count|max|proc)[^.]+$/           { split($1,h,".");  http[h[5]] = $3 }
	$1 ~ /^server\.resources\.controller_mysql_pool\.controller\.numconn.+$/        { split($1,cp,"."); connp[cp[5]] = $3 }
	$1 ~ /^server\.resources\.controller_mysql_pool\.[^.]+$/                        { split($1,cp,"."); connp[cp[4]] = $3 }
	END {
		last_requestcount = '$last_requestcount'
		last_epoch = '$last_epoch'
		current_epoch = '$current_epoch'
        	# https://javaee.github.io/glassfish/doc/5.0/administration-guide.pdf
        	printf "#section http-service:\n"
        	printf  "%s", "timestamp"       # output of date +%FT%T
        	printf ",%s", "http200"         # server.http-service.server.request.count200-count
        	printf ",%s", "http2xx"         # server.http-service.server.request.count2xx-count
        	printf ",%s", "http3xx"         # server.http-service.server.request.count3xx-count
        	printf ",%s", "http4xx"         # server.http-service.server.request.count4xx-count
        	printf ",%s", "http5xx"         # server.http-service.server.request.count5xx-count
        	printf ",%s", "http_not_2345xx" # server.http-service.server.request.countother-count
        	printf ",%s", "http_bytes_in"   # server.http-service.server.request.countbytesreceived-count
        	printf ",%s", "http_bytes_out"  # server.http-service.server.request.countbytestransmitted-count
        	printf ",%s", "http_requests"   # server.http-service.server.request.countrequests-count
        	printf ",%s", "http_maxtime"    # server.http-service.server.request.maxtime-count (ms)
        	printf ",%s", "http_avgtime"    # server.http-service.server.request.processingtime-count (ms)
        	printf "\n"
        	printf "%s", "'$TIMESTAMP'"
        	printf ",%s", http["count200-count"]
        	printf ",%s", http["count2xx-count"]
        	printf ",%s", http["count3xx-count"]
        	printf ",%s", http["count4xx-count"]
        	printf ",%s", http["count5xx-count"]
        	printf ",%s", http["countother-count"]
        	printf ",%s", http["countbytesreceived-count"]
        	printf ",%s", http["countbytestransmitted-count"]
        	printf ",%s", http["countrequests-count"]
        	printf ",%s", http["maxtime-count"]
        	printf ",%s", http["processingtime-count"]
        	printf "\n\n"
        	printf "#section thread-pool:\n"
        	printf  "%s", "timestamp"        # output of date +%FT%T
        	printf ",%s", "listener"         # listener name
        	printf ",%s", "conq_open"        # server.network.*.connection-queue.countopenconnections-count
        	printf ",%s", "conq_queued"      # server.network.*.connection-queue.countqueued-count
        	printf ",%s", "conq_oflow"       # server.network.*.connection-queue.countoverflows-count
        	printf ",%s", "conq_1minq"       # server.network.*.connection-queue.countqueued1minuteaverage-count
        	printf ",%s", "conq_5minq"       # server.network.*.connection-queue.countqueued5minutesaverage-count
        	printf ",%s", "conq_15minq"      # server.network.*.connection-queue.countqueued15minutesaverage-count
        	printf ",%s", "conq_totalq"      # server.network.*.connection-queue.counttotalqueued-count
        	printf ",%s", "conq_maxq"        # server.network.*.connection-queue.maxqueued-count
        	printf ",%s", "conq_peakq"       # server.network.*.connection-queue.peakqueued-count
        	printf ",%s", "conq_ticksq"      # server.network.*.connection-queue.tickstotalqueued-count
        	printf ",%s", "thrp_busy"        # server.network.*.thread-pool.currentthreadsbusy-count
        	printf ",%s", "thrp_max"         # server.network.*.thread-pool.maxthreads-count
        	printf ",%s", "thrp_total_tasks" # server.network.*.thread-pool.totalexecutedtasks-count
        	printf ",%s", "thrp_est_wait"    # COMPUTED: countqueued-count / [(http["countrequests-count"] - last_requestcount)/(current_epoch - last_epoch)]
        	printf "\n"
		if (last_epoch > 0) { 		# if not first call since monitor started when no prior counts exist
			service_rate = (http["countrequests-count"] - last_requestcount)/(current_epoch - last_epoch) 
		}
        	for (i in ln) {
                	printf "%s", "'$TIMESTAMP'"
                	printf ",%s", i
                	printf ",%s", connq[i".countopenconnections-count"]
                	printf ",%s", connq[i".countqueued-count"]
                	printf ",%s", connq[i".countoverflows-count"]
                	printf ",%s", connq[i".countqueued1minuteaverage-count"]
                	printf ",%s", connq[i".countqueued5minutesaverage-count"]
                	printf ",%s", connq[i".countqueued15minutesaverage-count"]
                	printf ",%s", connq[i".counttotalqueued-count"]
                	printf ",%s", (connq[i".maxqueued-count"] >= 0 ? connq[i".maxqueued-count"] : 9999)
                	printf ",%s", connq[i".peakqueued-count"]
                	printf ",%s", connq[i".tickstotalqueued-count"]
                	printf ",%s", thrp[i".currentthreadsbusy-count"]
                	printf ",%s", thrp[i".maxthreads-count"]
                	printf ",%s", thrp[i".totalexecutedtasks-count"]
			if (last_epoch > 0 && service_rate > 0) {
                		est_wait = connq[i".countqueued-count"] / service_rate		# estimated secs of waiting
			} else {		# just output zero as no prior requestcount exists
                		est_wait = 0
			}
                	printf ",%.0f", est_wait
                	printf "\n"
        	}
        	printf "\n"
        	printf "#section connection-pool:\n"
        	printf  "%s", "timestamp"       # output of date +%FT%T
        	printf ",%s", "pool"            # pool name
        	printf ",%s", "conp_avg_wait"   # server.resources.controller_mysql_pool.averageconnwaittime-count              NF==4
        	printf ",%s", "conp_peak_wait"  # server.resources.controller_mysql_pool.connrequestwaittime-highwatermark      NF==4
        	printf ",%s", "conp_acquired"   # server.resources.controller_mysql_pool.controller.numconnacquired-count       NF==5
        	printf ",%s", "conp_released"   # server.resources.controller_mysql_pool.controller.numconnreleased-count       NF==5
        	printf ",%s", "conp_used"       # server.resources.controller_mysql_pool.controller.numconnused-current         NF==5
        	printf ",%s", "conp_peak_used"  # server.resources.controller_mysql_pool.controller.numconnused-highwatermark   NF==5
        	printf ",%s", "conp_size_waitq" # server.resources.controller_mysql_pool.waitqueuelength-count                  NF==4
        	printf ",%s", "conp_free"       # server.resources.controller_mysql_pool.numconnfree-current                    NF==4
        	printf ",%s", "conp_timedout"   # server.resources.controller_mysql_pool.numconntimedout-count                  NF==4
        	printf "\n"
        	printf "%s", "'$TIMESTAMP'"
        	printf ",%s", "controller_mysql_pool"
        	printf ",%s", connp["averageconnwaittime-count"]
        	printf ",%s", connp["connrequestwaittime-highwatermark"]
        	printf ",%s", connp["numconnacquired-count"]
        	printf ",%s", connp["numconnreleased-count"]
        	printf ",%s", connp["numconnused-current"]
        	printf ",%s", connp["numconnused-highwatermark"]
        	printf ",%s", connp["waitqueuelength-count"]
        	printf ",%s", connp["numconnfree-current"]
        	printf ",%s", connp["numconntimedout-count"]
        	printf "\n\n"
	}'
}

# helper function to save last recorded Glassfish http request count for "server" (since JVM start) 
# from monitor output via STDIN along with its timestamp and write to STDOUT the string: <requestcount>
function get_request_count {
	(( $# == 0 )) ||  err "Usage: ${FUNCNAME[0]}"
	local pattern='^[[:digit:]]+$'
	
	requestcount=$(awk '$1=="server.http-service.server.request.countrequests-count" {print $3}')
	[[ "$requestcount" =~ $pattern ]] || { warn "unable to find server.http-service.server.request.countrequests-count value"; return 1; }
	echo "$requestcount"
}

function gfpools {
	local FN=gfpools
	local LOGF=$(mk_logname $FN)
	local M R prev_reqcount datetime epoch_secs

	# verify that running from controller install directory
	[[ -f ./db/db.cnf ]] || { warn "unable to find ./db/db.cnf. Please run from controller install directory. Disabling $FN monitor."; return 1; }
	type awk &> /dev/null || { warn "unable to find awk command. Install with yum install gawk. Disabling $FN monitor."; return 1; }
	exist_asadmin_creds || { warn "asadmin credentials unavailable. Create formatted .passwordfile. Disabling $FN monitor."; return 1; }

	( while true ; do
		sleep 0.95
		(( $(date +%s) % 59 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		check_asadmin_connection 2> /dev/null || { sleep 300; continue; }	# retry Glassfish connection later

		M=$(timeout 30s bash -c '$ASADMIN<(echo $ASCREDS) get --monitor server."*"' 2>&1)
		R=$? 
		if (( $R == 0 )) && [[ -n "$M" ]] ; then
			datetime=$(date +%FT%T)
			epoch_secs=$(date +%s --date $datetime)
		   	parse_gf_mon "$datetime" "$prev_reqcount" <<< "$M" >> $LOGF
		   	prev_reqcount=$(get_request_count <<< "$M") || err "get_request_count failed within ${FUNCNAME[0]}. Disabling $FN monitor."
			prev_reqcount="$epoch_secs,$prev_reqcount"
		elif (( $R == 124 )) ; then
		   	echo "#section error:"$'\n'"$(date +'%FT%T') \"Glassfish asadmin timed out\" retc=$R"$'\n' >> $LOGF
		else
		   	echo "#section error:"$'\n'"$(date +'%FT%T') \"Glassfish asadmin call failed\" retc=$R:$M"$'\n' >> $LOGF
		fi
	done ) &
}

# per process I/O totals to date as reported by /proc/[pid]/io
function proc_io {
	local FN=procio
	local LOGF=$(mk_logname $FN)

	# verify that running from controller install directory
	[[ -f ./db/db.cnf ]] || { warn "unable to find ./db/db.cnf. Please run from controller install directory. Disabling $FN monitor."; return 1; }

	( while true ; do
		sleep 0.95
		(( $(date +%s) % 60 == 0 )) || continue
		(( $(date +%s) < $DEADLINE )) || exit 0
		local mysqlpid=$(pgrep -f "[m]ysqld .*--port=$(awk -F= '$1 == "port" {print $2}' db/db.cnf)") 
		local gfpid=$(pgrep -f "[g]lassfish.jar .*-javaagent:")
		local sql gf datetime_m datetime_g txt
		datetime_m=$(date +%FT%T)
		if [[ -n "${mysqlpid:-}" ]] ; then
			txt="mysql "$(sed 's/: /=/' /proc/$mysqlpid/io 2>&1) && sql=$txt || sql="UNABLE_TO_READ_/proc/$mysqlpid/io [$txt]"
		else
			sql="NO_MYSQL_RUNNING"
		fi
		datetime_g=$(date +%FT%T)
		if [[ -n "${gfpid:-}" ]] ; then
			txt="gf "$(sed 's/: /=/' /proc/$gfpid/io 2>&1) && gf=$txt || gf="UNABLE_TO_READ_/proc/$gfpid/io [$gf]"
		else
			gf="NO_GLASSFISH_RUNNING"
		fi
		echo "$datetime_m "$sql$'\n'"$datetime_g "$gf >> $LOGF
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

setup_assoc_array monitor "(i=run_iostat v=run_vmstat d=run_dbtest dv=run_dbvars f=run_fdcount m=run_memsize p=port_count n1=numa_buddyrefs n2=numa_stat sl=slowlog oo=one_offs gf=gfpools io=proc_io)"

declare OPTIONS=$(IFS=,; echo "${monitor_LAB[*]}")			# list of current options
declare USAGESTR="Usage: 
$PROGNAME [-t <ticket_number>]
	[-n]	Do not try to persist MySQL password if none available
	[-m <one of more of $OPTIONS to monitor>]
	[-x <one or more of $OPTIONS to NOT monitor>]
	[-S <4d to stop after 4 days. Can use one of M,h,d,w,m durations for Mins,hours,days,weeks,months>]
Where
$(IFS=$'\n';paste <(echo "${monitor_LAB[*]}") <(echo "${monitor_VAL[*]}"))"
EARGS="$*"								# original entered args
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
		x  ) 	unset mons; declare -a mons			# exclude these monitors
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
		S  )	declare pattern='^([[:digit:]]+)(h|d|w|m|M)$'
			[[ $OPTARG =~ $pattern ]] || err "$USAGESTR"
			declare number=${BASH_REMATCH[1]} unit=${BASH_REMATCH[2]}
			case $unit in
				M ) increment=$(( $number * 60 )) ;;
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

info "$PROGNAME started with args: $EARGS"

# check for and persist MYSQL root password - unless forbidden
if [[ -z "$DONT_SAVE_PASSWD" ]] ; then
	persist_mysql_passwd
	persist_asadmin_passwd
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
if [[ -n "$(ls ${LOGDIR}/${STEMNAME}.pid 2>/dev/null)" ]] ; then
	kill -15 $(cat ${LOGDIR}/${STEMNAME}.pid) 2> /dev/null
	rm -f ${LOGDIR}/${STEMNAME}.pid 2> /dev/null
fi
# clean up for any earlier monX versions <-- ASSUMING script STEMNAME of form <something>[[:digit:]]+_e
NVSTEM=${STEMNAME%_e} NVSTEM=${NVSTEM%%[[:digit:]]*}
if [[ -n "$(ls ${LOGDIR}/${NVSTEM}*.pid 2>/dev/null)" ]] ; then
	kill -15 $(cat ${LOGDIR}/${NVSTEM}*.pid) 2>/dev/null
	rm -f ${LOGDIR}/${NVSTEM}*.pid 2> /dev/null
fi

for i in ${!to_monitor_*}; do
	${!i}			# run monitor (assumes will background itself)
done
echo -$$ > ${LOGDIR}/${STEMNAME}.pid	# all sub-processes are in same process group

info "kill monitors with \"kill -15 "$(cat ${LOGDIR}/${STEMNAME}.pid)"\""
