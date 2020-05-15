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
export -f getpw

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
export -f save_mysql_passwd

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
export -f save_asadmin_passwd

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
export -f get_mysql_passwd

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
export -f get_asadmin_passwd

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
export -f persist_mysql_passwd

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
export -f persist_asadmin_passwd

function get_dbport {
	if [[ ! -f ./db/db.cnf ]] ; then
		err "unable to find ./db/db.cnf. Please run from controller install directory."
		return 1
	fi

	awk -F= '$1 =="port" {print $2}' ./db/db.cnf
}
export -f get_dbport

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
export -f mysqlclient

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
export -f setup_mysql_connect
