#!/bin/bash

#
# generate dump & restore scripts as part of a controller MySQL rescue package for corrupt databases. 
#
# $Id: dumprestore-gen.sh 1.0 2020-09-03 19:59:50 robnav $

PROGNAME=${0##*/}
STEMNAME=${PROGNAME%%.*}

USAGESTR="Usage: $PROGNAME -w|-l [ -s <major version number to match>|\"\" ] 	# windows or linux with optional list of what exists
			-v <version number with at least 2 dots> | -d  <URL>|<dirname>|<file>.{gz,tar,zip} "

# [experimental] declare intentional uninitialised globals here
MATCHING_DATADIR=
PLATFORM=
DATA=
DEBUG=
TDIR=
MATCHVERSION=

#  err "some message" [optional return code]
function err {
   local exitcode=${2:-1}                               # default to exit 1
   local c=($(caller 0))                                        # who called me?
   local r="${c[2]} (f=${c[1]},l=${c[0]})"                       # where in code?

   echo "ERROR: $r failed: $1" 1>&2
#   echo "[#|$(date +'%FT%T')|ERROR|$r failed: $1|#]" >> $MLOGF

   exit $exitcode
}

function warn {
   echo "WARN: $1" 1>&2
#   echo "[#|$(date +'%FT%T')|WARN|$1|#]" >> $MLOGF
}

function info {
   echo "INFO: $1" 1>&2
#   echo "[#|$(date +'%FT%T')|INFO|$1|#]" >> $MLOGF
}

function cleanup {
	rm -rf $TDIR &>/dev/null
}

# make curl call and either return actual text else fixed literal 'CURL_FAILED'
function call_curl {
        (( $# >= 1 )) || err "Usage: ${FUNCNAME[0]} <curl args>"
        local curl_resp text retc

        curl_resp=$(curl -m 2 -s -w "%{http_code}" "$@" 2>&1) || { retc=$?; warn "curl $@ failed: $curl_resp ($retc)"; return $retc; }
        if [[ ${curl_resp: -3:1} == 2 ]] ; then         # all 2xx codes are SUCCESS
                text=${curl_resp:0: $((${#curl_resp}-3))}			# patch to run on MacOS Bash - that is too old
        else
                text=CURL_FAILED
        fi
        [[ "$text" == "CURL_FAILED" ]] && return 1 || { [[ -n "$text" ]] && echo "$text"; return 0; }
}

# permit loose equality comparison of dotted version numbers so that the following happens:
#  4.5.6    [eq]  4.5.6.X
#  4        [neq] 4.5.6.1
#  4.5      [neq] 4.5.6.1
#  4.5      [neq] 4.5.6
#  4.5.6.1  [neq] 4.5.6.5
#  20.3.7.2 [eq] 20.3.7.2
function compare_version_eq {
	(( $# == 2 )) || err "Usage: ${FUNCNAME[0]} <version1> <version2>"
	local version1=$1 version2=$2 ndots1 ndots2 lvers1 lvers2

	ndots1=$(awk -F. '{ print NF-1 }' <<< "$version1")
	ndots2=$(awk -F. '{ print NF-1 }' <<< "$version2")
	diffdots=$((ndots1 - ndots2))
	diffdots=${diffdots#-}		# arithmetic absolute 
	mindots=$(( ndots1 < ndots2 ? ndots1 : ndots2 ))

	if (( ndots1 == ndots2 )); then
		[[ "$version1" == "$version2" ]] && return 0 || return 1
	elif (( diffdots > 1 || mindots < 2 )); then
		return 1
	else		# dot count differs by 1 only and both have at least 2 dots
		# derive substring from both with $mindots separators
		lvers1=$(awk -F. '{for (i=1;i<='$((mindots+1))';++i) {v=(v "." ($i))}; print substr(v,2)}' <<< "$version1")
		lvers2=$(awk -F. '{for (i=1;i<='$((mindots+1))';++i) {v=(v "." ($i))}; print substr(v,2)}' <<< "$version2")
		[[ "$lvers1" == "$lvers2" ]] && return 0 || return 1
	fi
}

# show all available 
function matching_versions {
	(( $# == 2 )) || err "Usage: ${FUNCNAME[0]} <platform> <version pattern>"
	local platform=$1 vers=$2

	type aws &>/dev/null || err "needs AWScli installed (MacOS: brew install awscli)"
	type awk &>/dev/null || err "needs AWK installed"

	aws s3 ls appdynamics-cs-support-system/db/${platform}/ --recursive | awk -F/ '$NF ~ /data-'"$vers"'/ { print $NF }'
}

# ensure that entered version is of form: \d+.\d+.\d+(.\d+)?
# i.e. at least 3 numerics with 2 separation dots
function validate_version {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <version number>"
	local vers=$1

	local pattern='^[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+(\.[[:digit:]]+)?$'
	[[ "$vers" =~ $pattern ]] && return 0 || return 1
}

# pull AppD controller version out of db/data/controller/global_configuration_cluster.ibd
function get_version {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <datadir>"
	local datadir=$1 lvers found_vers
	
	type strings &>/dev/null || err "strings must be installed. Install binutils package and retry"
	[[ -f ${datadir}/controller/global_configuration_cluster.ibd ]] || { warn "no controller/global_configuration_cluster.ibd found within $datadir"; return 1; }
	lvers=$(strings ${datadir}/controller/global_configuration_cluster.ibd | awk -F. '$0 ~ /to track upgrade/ {print $NF}' | tail -1)
	# reformat 004-005-018-000 to 4.5.18.0
	found_vers=$(awk -F- '{ for (i=1;i<=NF;++i) { v=(v sprintf(".%s", 0+$i)) }} END { print substr(v,2) }' <<< "$lvers")	
	if validate_version "$found_vers"; then
		echo "$found_vers"
		return 0
	else
		warn "string $found_vers is not a valid version"
		return 1
	fi
}

# crudely determine if supplied putative MySQL datadir is in fact such a beast
# observed that all AppD MySQL datadirs have at least 1100 files & directories
function validate_data {
	(( $# >=3 )) || err "Usage: ${FUNCNAME[0]} <platform> <datadir> <matching_datadir> <expected version>"
	local platform=$1 datadir=$2 matching_datadir=$3 expected_version=$4 found_vers l_numf u_numf

	(( $(find -L $datadir -print | wc -l) > 1100 )) || { warn "${FUNCNAME[0]}: not enough files in supplied datadir"; return 1; }

	# Check for wrong-platform data.zip - prevent accidentally including useless data.zip with dump/restore package
	# windows MySQL datadir contains lower case *partmax*.ibd files: metricdata_min#p#partmax#sp#partmaxsp0.ibd 
	# whereas linux MySQL contain UPPER case *PARTMAX*.ibd files: metricdata_min#P#PARTMAX#SP#PARTMAXsp0.ibd
	u_numf=$(find -L $datadir -type f -name '*'PARTMAX'*'.ibd | wc -l)
	l_numf=$(find -L $datadir -type f -name '*'partmax'*'.ibd | wc -l)
	if ( [[ "$platform" == "linux" && "$matching_datadir" == true ]] || [[ "$platform" == "windows" && "$matching_datadir" == false ]] ) && (( l_numf > 0 )); then 
		warn "${FUNCNAME[0]}: platform=$platform, matching_datadir=$matching_datadir but lowercase 'partmax.ibd' files found. Windows datadir within $datadir?"
		return 1
	fi
	if ( [[ "$platform" == "windows" && "$matching_datadir" == true ]] || [[ "$platform" == "linux" && "$matching_datadir" == false ]] ) && (( u_numf > 0 )); then 
		warn "${FUNCNAME[0]}: platform=$platform, matching_datadir=$matching_datadir but uppercase 'PARTMAX.ibd' files found. Linux datadir within $datadir?"
		return 1
	fi

	found_vers=$(get_version "$datadir") || return 1
	validate_version "$found_vers" || { warn "${FUNCNAME[0]}: invalid version found '$found_vers' within $datadir"; return 1; }

	if [[ -n "$expected_version" ]] ; then
		compare_version_eq "$expected_version" "$found_vers" || { warn "${FUNCNAME[0]}: expected to find '$expected_version' instead found '$found_vers'"; return 1; }
	fi
	return 0
}

# unpacks an archive (usually .zip) into $tempdir/data whether or not the archive already contained data sub-directory
# called as:
# unpack_to_data <archive> <archive_type> <tempdir>
function unpack_to_data {
	(( $# == 3 )) || err "Usage: ${FUNCNAME[0]} <archive> <archive_type> <tempdir>"
	local archive=$1 atype=$2 tempdir=$3 retc

	mkdir -p $tempdir/tmp >/dev/null || { retc=$?; warn "unable to mkdir -p $tempdir/tmp ($retc)"; return 1; }
	if [[ "$atype" == "zip" ]] ; then
		( cd $tempdir/tmp; unzip "$archive" >/dev/null; ) || { retc=$?; warn "unable to unzip $archive ($retc)"; return 1; }
	else
		warn "invalid archive type '$atype'... giving up"
		return 1
	fi
	# at this point it is not clear whether there is a data directory name or not. Make one if not
	if [[ -d "$tempdir/tmp/data" ]] ; then
		mv $tempdir/tmp/data $tempdir >/dev/null || { retc=$?; warn "unable to mv $tempdir/tmp/data $tempdir ($retc)"; return 1; }
	else
		mv $tempdir/tmp $tempdir/data >/dev/null || { retc=$?; warn "unable to mv $tempdir/tmp $tempdir/data ($retc)"; return 1; }
	fi
	[[ -d "$tempdir"/data ]] || { warn "unable to find 'data' directory after unpacking $archive into $tempdir"; return 1; }
}

# logical function to check that supplied datadir and platform are consistent - helps to avoid expensive mixups
function datadir_matches {
	(( $# == 2 )) || err "Usage: ${FUNCNAME[0]} <datadir> <platform>"
	local datadir=$1 platform=$2 u_numf l_numf

	# windows MySQL datadir contains lower case *partmax*.ibd files: metricdata_min#p#partmax#sp#partmaxsp0.ibd 
	# whereas linux MySQL contain UPPER case *PARTMAX*.ibd files: metricdata_min#P#PARTMAX#SP#PARTMAXsp0.ibd
	u_numf=$(awk 'END {print NR}' <(find -L $datadir -type f -name '*'PARTMAX'*'.ibd 2>/dev/null))
	l_numf=$(awk 'END {print NR}' <(find -L $datadir -type f -name '*'partmax'*'.ibd 2>/dev/null))
	(( u_numf > 0 && l_numf > 0 || u_numf == 0 && l_numf == 0 )) && err "invalid datadir: $datadir (u_numf=$u_numf, l_numf=$l_numf)"
	if [[ "$platform" == "linux" ]] && (( u_numf > 0 && l_numf == 0 )); then 
		return 0
	elif [[ "$platform" == "windows" ]] && (( l_numf > 0 && u_numf == 0 )); then
		return 0
	else
		return 1
	fi
}

# use a supplied version number to download a data-<VERSION>.zip from S3
# Interesting note: can use either windows or linux data.zip to generate dump/restore syntax - though still need platform specific data.zip
# for repairing MySQL. matching_datadir=false for case when using windows.zip for a Linux dump/restore code generation and vice-versa.
# Note: there are two return values from this function that is usually run in a sub-shell $(...) - they are comma separated within the STDOUT print
function get_data_from_aws {
	(( $# == 3 )) || err "Usage: ${FUNCNAME[0]} <version number> <windows|linux> <tempdir>"
	local version=$1 platform=$2 tempdir=$3 other_platform matching_datadir

	if (cd $tempdir; call_curl -O https://s3-us-west-1.amazonaws.com/appdynamics-cs-support-system/db/${platform}/data-${version}.zip || exit 1; ); then 
		matching_datadir=true
	else
		other_platform=$( if [[ "$platform" == "linux" ]]; then echo "windows"; elif [[ "$platform" == "windows" ]]; then echo "linux"; else exit 1; fi ) || err "invalid program state: unrecognised platform: $platform"
		warn "unable to download db/${platform}/data-${version}.zip from AWS...searching $other_platform files"
		rm -f $tempdir/data-${version}.zip &>/dev/null
		if (cd $tempdir; call_curl -O https://s3-us-west-1.amazonaws.com/appdynamics-cs-support-system/db/${other_platform}/data-${version}.zip || exit 1; ); then
			matching_datadir=false
		else
			err "unable to find matching data-${version}.zip for any support platform, giving up"
		fi
	fi

	unpack_to_data "$tempdir/data-${version}.zip" "zip" "$tempdir" || return 1
	validate_data "$platform" "$tempdir/data" "$matching_datadir" "$version" || return 1
	echo "$matching_datadir,$tempdir/data"
}

# generalised way to convert a URL, directory or zip file reference into acceptable MySQL datadir
# NOTE:
# - no current way to determine if referred to datadir is for current platform or not (maybe case specific tests?)
function get_data {
	(( $# == 3 )) || err "Usage: ${FUNCNAME[0]} <platform> <data url, dir or zipfile> <tempdir>"
	local platform=$1 dataref=$2 tempdir=$3 fname ldatadir retc matching_datadir

	# assume prefix of http:// or https:// refers to URL
	if [[ "${dataref:0:7}" == "http://" || "${dataref:0:8}" == "https://" ]]; then		# URL pointing to .zip containing data/
		(cd $tempdir; call_curl -O $dataref >/dev/null|| exit 1; ) || { warn "unable to download $dataref"; return 1; }
		fname=$(ls -1tr $tempdir | tail -1)
		[[ -n "$fname" ]] || { warn "unable to find downloaded file within $tempdir"; return 1; }
		[[ "${fname: -4:4}" == ".zip" ]] || { warn "only .zip files supported"; return 1; }
		unpack_to_data "$tempdir/$fname" "zip" $tempdir || return 1
		ldatadir=$tempdir/data
	elif [[ -d "$dataref" ]]; then								# existing directory
		(cd $tempdir; ln -s $dataref data >/dev/null; ) || { retc=$?; warn "failed to ln -s $dataref data ($retc)"; return 1; }
		ldatadir="$tempdir/data"
	elif [[ -f "$dataref" ]]; then								# local .zip file containing data/
		[[ "${dataref: -4:4}" == ".zip" ]] || { warn "only .zip files supported"; return 1; }
		[[ "${dataref:0:1}" == "/" ]] || dataref="$(pwd)/$dataref"
		unpack_to_data "$dataref" "zip" $tempdir || return 1
		ldatadir=$tempdir/data
	else
		err "unrecognised data.zip reference: $dataref"$'\n'"$USAGESTR"
	fi

	matching_datadir=$( if datadir_matches "$ldatadir" "$platform"; then echo true; else echo false; fi )
	validate_data "$platform" "$ldatadir" "$matching_datadir" || return 1
	echo "$matching_datadir,$ldatadir"
}

function generate_md_dump {
	(( $# == 4 )) || err "Usage: ${FUNCNAME[0]} <platform> <version> <datadir> <tempdir>"
	local platform=$1 version=$2 datadir=$3 tempdir=$4 IGNORELIST DBLIST GENVERSION f str

	# we have a linux datadir if we successfully downloaded that for requested linux platform or got it as a fall back from a requested windows
	[[ -n "$MATCHING_DATADIR" ]] || err "unexpectedly empty MATCHING_DATADIR. Giving up..."
	( [[ "$platform" == "linux" && "$MATCHING_DATADIR" == true ]] || [[ "$platform" == "windows" && "$MATCHING_DATADIR" == false ]] ) && str="PARTMAX"
	( [[ "$platform" == "windows" && "$MATCHING_DATADIR" == true ]] || [[ "$platform" == "linux" && "$MATCHING_DATADIR" == false ]] ) && str="partmax"
	[[ -n "$str" ]] || err "unexpectedly empty str. Giving up..."
        for f in $(find -L $datadir/controller -type f -name '*'$str'*'.ibd | sed -e 's/#.*$//' -e 's,^.*/,,' | sort -u); do
		IGNORELIST="$IGNORELIST --ignore-table=controller.$f"
	done
	
	[[ -n "$IGNORELIST" ]] || err "empty IGNORELIST !!"
	DBLIST="--databases controller "$(cd $datadir; ls -d eum* mds* 2>/dev/null |tr '\n' ' ')
	GENVERSION="Generated for controller version $version by $(id -un) using $PROGNAME on $(date +%FT%T)"
	mkdir -p $tempdir/gen 2>/dev/null || { warn "${FUNCNAME[0]}: unable to mkdir $tempdir/gen"; return 1; }

	if [[ "$platform" == "windows" ]]; then
		f="$tempdir/gen/dump_md_${version}.cmd"
		# following HERE script only works because DOS cmds currently use no '$'. If that changes then unquoted EOT will permit variable expansion therein. Beware !
		cat << EOT > "$f"
@echo off

rem
rem $GENVERSION
rem
rem Can be called with up to two arguments ARG1 for DUMPDIR and ARG2 for PORT. There is no way to specify command line arg for PORT 
rem without also specifying DUMPDIR. Sorry. My DOS foo is currently not high enough.		ran Aug-2020
rem

setlocal enabledelayedexpansion

set PARAM=%1
if defined PARAM (
	set DUMPDIR=%1
) else (
	set DUMPDIR=..\dump01
)

set PARAM=%2
if defined PARAM (
	set PORT=%2
) else (
	set PORT=3388
)

set LOG=%DUMPDIR%\dr.log
set PORT=%PORT%
set DUMPER=db\bin\mysqldump.exe
set MYSQL_OPTS=--user=root -p --protocol=TCP --port=%PORT%

mkdir "%DUMPDIR%" >nul 2>&1
compact /c "%DUMPDIR%" >nul

if not exist "%DUMPDIR%" (
	echo Error (^%ERRORLEVEL%^): unable to access Dumpdir %DUMPDIR%. Please change DUMPDIR value and then retry.
	echo Error (^%ERRORLEVEL%^): unable to access dumpdir %DUMPDIR%. Please change DUMPDIR value and then retry. >>"%LOG%"
	exit /b 1
)

if not exist "%DUMPER%" (
	echo Error (^%ERRORLEVEL%^): unable to access %DUMPER%. Please cd [controller install dir] and retry.
	echo Error (^%ERRORLEVEL%^): unable to access %DUMPER%. Please cd [controller install dir] and retry. >>"%LOG%"
	exit /b 1
)

rem	empty log
echo > "%LOG%"
set DATESTR=%DATE:~10,4%-%DATE:~7,2%-%DATE:~4,2%T%TIME:~0,2%:%TIME:~3,2%:%TIME:~6,2%
echo %DATESTR%: Starting dump...
echo %DATESTR%: Starting dump... >> "%LOG%"

echo MySQL Port: %PORT%
echo    DumpDir: %DUMPDIR%
echo    LogFile: %LOG%
echo.

%DUMPER% -v --single-transaction --skip-lock-tables  --set-gtid-purged=off --routines --result-file=%DUMPDIR%\metadata.tmp %MYSQL_OPTS% $IGNORELIST $DBLIST 2>>"%LOG%"
if %ERRORLEVEL% NEQ 0 (
	echo Error (^%ERRORLEVEL%^): metadata dump issue.
	echo See log: %LOG%
	echo Error (^%ERRORLEVEL%^): metadata dump issue. >>"%LOG%"
	exit /b 1
) else (
	move "%DUMPDIR%\metadata.tmp" "%DUMPDIR%\metadata.sql" >nul
	set DATESTR=%DATE:~10,4%-%DATE:~7,2%-%DATE:~4,2%T%TIME:~0,2%:%TIME:~3,2%:%TIME:~6,2%
	echo !DATESTR!: Ending dump with no detected error
	echo !DATESTR!: Ending dump with no detected error. >> "%LOG%"
)
EOT
		(( $? == 0 )) || { warn "detected error in generating $f"; return 1; }
	elif [[ "$platform" == "linux" ]]; then
		:
	fi
}

function generate_md_restore {
	(( $# == 4 )) || err "Usage: ${FUNCNAME[0]} <platform> <version> <datadir> <tempdir>"
	local platform=$1 version=$2 datadir=$3 tempdir=$4 GENVERSION f

	GENVERSION="Generated for controller version $version by $(id -un) using $PROGNAME on $(date +%FT%T)"
        mkdir -p $tempdir/gen 2>/dev/null || { warn "${FUNCNAME[0]}: unable to mkdir $tempdir/gen"; return 1; }

        if [[ "$platform" == "windows" ]]; then
                f="$tempdir/gen/restore_md_${version}.cmd"
                # following HERE script only works because DOS cmds currently use no '$'. If that changes then unquoted EOT will permit variable expansion therein. Beware !
                cat << EOT > "$f"
@echo off

rem
rem $GENVERSION
rem
rem Can be called with up to two arguments ARG1 for DUMPDIR and ARG2 for PORT. There is no way to specify command line arg for PORT 
rem without also specifying DUMPDIR. Sorry. My DOS foo is currently not high enough.		ran Aug-2020
rem

setlocal enabledelayedexpansion

set PARAM=%1
if defined PARAM (
	set DUMPDIR=%1
) else (
	set DUMPDIR=..\dump01
)

set PARAM=%2
if defined PARAM (
	set PORT=%2
) else (
	set PORT=3388
)

set LOG=%DUMPDIR%\dr.log
set DUMPFILE=%DUMPDIR%\metadata.sql
set PORT=%PORT%
set CLIENT=db\bin\mysql.exe
set MYSQL_OPTS=--user=root -p --protocol=TCP --port=%PORT%

mkdir "%DUMPDIR%" >nul 2>&1
compact /c "%DUMPDIR%" >nul

if not exist "%DUMPDIR%" (
	echo Error (^%ERRORLEVEL%^): unable to access Dumpdir %DUMPDIR%. Please change DUMPDIR value and then retry.
	echo Error (^%ERRORLEVEL%^): unable to access dumpdir %DUMPDIR%. Please change DUMPDIR value and then retry. >>"%LOG%"
	exit /b 1
)

if not exist "%DUMPFILE%" (
	echo Error (^%ERRORLEVEL%^): unable to access metadata dump %DUMPFILE%.
	echo Error (^%ERRORLEVEL%^): unable to access dumpdir %DUMPDIR%. >>"%LOG%"
	exit /b 1
)

if not exist "%CLIENT%" (
	echo Error (^%ERRORLEVEL%^): unable to access %CLIENT%. Please cd [controller install dir] and retry.
	echo Error (^%ERRORLEVEL%^): unable to access %CLIENT%. Please cd [controller install dir] and retry. >>"%LOG%"
	exit /b 1
)

set DATESTR=%DATE:~10,4%-%DATE:~7,2%-%DATE:~4,2%T%TIME:~0,2%:%TIME:~3,2%:%TIME:~6,2%
echo %DATESTR%: Starting restore...
echo %DATESTR%: Starting restore... >> "%LOG%"

echo MySQL Port: %PORT%
echo    DumpDir: %DUMPDIR%
echo    LogFile: %LOG%
echo.

%CLIENT% %MYSQL_OPTS% -A controller < %DUMPFILE% 2>>"%LOG%"
if %ERRORLEVEL% NEQ 0 (
	echo Error (^%ERRORLEVEL%^): metadata restore issue.
	echo See log: %LOG%
	echo Error (^%ERRORLEVEL%^): metadata restore issue. >>"%LOG%"
	exit /b 1
) else (
	move %DUMPDIR%\metadata.sql %DUMPDIR%\metadata.done >nul
	set DATESTR=%DATE:~10,4%-%DATE:~7,2%-%DATE:~4,2%T%TIME:~0,2%:%TIME:~3,2%:%TIME:~6,2%
	echo !DATESTR!: Ending restore with no detected error
	echo !DATESTR!: Ending restore with no detected error. >> "%LOG%"
)
EOT
		(( $? == 0 )) || { warn "detected error in generating $f"; return 1; }
	elif [[ "$platform" == "linux" ]]; then
		:
	fi
}

function generate_full_dump {
	:
}

function generate_full_restore {
	:
}

# recall it is possible to be pointed at existing unpacked datadir (i.e. not have data-xyz.zip ready)
# via -d <dir> parameter. This explains need for separate <datadir> and <tempdir> args
function build_dr_package {
	(( $# == 4 )) || err "Usage: ${FUNCNAME[0]} <platform> <version> <datadir> <tempdir>"
	local platform=$1 version=$2 datadir=$3 tempdir=$4 pwd=$(pwd) retc
	local fname=$tempdir/data-${version}.zip pkgname="dr-${platform}-${version}.zip" ofname=data-${platform}-${version}.zip

	if $MATCHING_DATADIR ; then
		if [[ -f "$fname" ]]; then 
			cp $fname $tempdir/gen/${ofname} || { retc=$?; warn "final copy of $fname to $tempdir/gen/$ofname failed ($retc)...continuing on"; }
		elif [[ -d "$datadir" ]]; then
			(cd $datadir; zip -r $tempdir/gen/$ofname . >/dev/null; ) || { retc=$?; warn "zip -r $tempdir/gen/$ofname failed ($retc)"; return 1; }
		fi
	fi
	
	# finally make dump/restore package
	rm -f "$pwd/$pkgname" &>/dev/null
	(cd $tempdir/gen; zip -r $pwd/$pkgname . > /dev/null; ) || { retc=$?; warn "zip -r $pwd/$pkgname failed ($retc)"; return 1; }
	info "$pwd/$pkgname $(ls -n $pwd/$pkgname | awk '{print $5}') bytes" || return 1
}

#####################################################################
# Main Body
#####################################################################
type unzip &>/dev/null || err "unzip must be installed"
type zip &>/dev/null || err "zip must be installed"
TDIR=$(mktemp -d -t tmp.XXXXXXXXXX) || err "mktemp failed"

while getopts ":d:ulwv:Ds:" OPT ; do
        case $OPT in
                u  ) PLATFORM=linux
                        ;;
                l  ) PLATFORM=linux
                        ;;
                w  ) PLATFORM=windows
                        ;;
                v  ) VERSION=$OPTARG
                        ;;
		d  ) DATA=$OPTARG
			;;
                D  ) DEBUG=true
                        ;;
                s  ) MATCHVERSION=$OPTARG
                        ;;
                :  ) err "$0: option '$OPTARG' requires a value"$'\n'"$USAGESTR"
                        ;;
                \? ) err "$USAGESTR"
                        ;;
        esac
done
shift $(( $OPTIND - 1 ))
[[ "$DEBUG" == "true" ]] || trap cleanup EXIT			# automatically tidy up scratch space upon exit

# check for valid arg combinations
[[ -n "$PLATFORM" ]] || err "missing -w|-l plaform specification"$'\n'"$USAGESTR"
[[ -n "$MATCHVERSION" ]] && { matching_versions "$PLATFORM" "$MATCHVERSION" || exit 1; exit 0; }
[[ -n "$VERSION" ]] && ( validate_version $VERSION  || err "Invalid version: $VERSION"$'\n'"$USAGESTR" )
( [[ -z "$VERSION" && -z "$DATA" ]] || [[ -n "$VERSION" && -n "$DATA" ]] ) && err "$USAGESTR"

# fetch/pre-process datadir reference
if [[ -n "$VERSION" ]]; then
	response=$(get_data_from_aws "$VERSION" "$PLATFORM" "$TDIR") || exit 1
	IFS=, read -r MATCHING_DATADIR DATADIR <<< "$response"          # unpack tuple response
fi

if [[ -n "$DATA" ]]; then
	response=$(get_data "$PLATFORM" "$DATA" "$TDIR") || exit 1
	IFS=, read -r MATCHING_DATADIR DATADIR <<< "$response"		# unpack tuple response
fi

[[ -n "$DATADIR" ]] || err "failed to assign DATADIR...giving up"	# at this point either -v or -d arg should have led to DATADIR existing
[[ -n "$MATCHING_DATADIR" ]] || err "failed to assign MATCHING_DATADIR...giving up"
[[ -z "$VERSION" ]] && { VERSION=$(get_version "$DATADIR") || exit 1; }

# finally generate dump/restore package
generate_md_dump "$PLATFORM" "$VERSION" "$DATADIR" "$TDIR" || exit 1
generate_md_restore "$PLATFORM" "$VERSION" "$DATADIR" "$TDIR" || exit 1

generate_full_dump "$PLATFORM" "$VERSION" "$DATADIR" "$TDIR" || exit 1
generate_full_restore "$PLATFORM" "$VERSION" "$DATADIR" "$TDIR" || exit 1

build_dr_package "$PLATFORM" "$VERSION" "$DATADIR" "$TDIR" || exit 1
