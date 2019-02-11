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
