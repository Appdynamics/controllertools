#!/bin/bash

#
# simplify enabling/disabling the new controller metric stream writer
#
#
# Best test settings for On-prem controller as of 7-May-2021:
# dis.metrics.stream-writer.threads=16
# dis.metrics.stream-writer.batchsize=10000
# write.thread.count=16
#
# i.e. ./streamctl.sh -e 16 -s
#

#APPD_ROOT=/opt/appdynamics/platform/4.5.17/product/controller

USAGESTR="Usage: $0 -e <#threads>[,<batchsz>]|-d [-s]"

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

###########################################################################################################
# Main body
###########################################################################################################
[[ -f ./db/db.cnf ]] || { echo "Please cd to controller install directory and re-run" 1>&2; exit 1; }
APPD_ROOT=$(pwd -P)
while getopts ":e:sd" OPT ; do
        case $OPT in
                e )     pattern='^[[:digit:]]+(,[[:digit:]]+)*$'
			[[ "$OPTARG" =~ $pattern ]] || err "$USAGESTR"
			IFS=, read -a CONFIG <<< "$OPTARG"
			NUM_THREADS=${CONFIG[0]}
			BATCHSZ=${CONFIG[1]:-10000}
			ENABLED=1
                        ;;
                d )     DISABLED=1
                        ;;
		s )	STATUS=1
			;;
                : )     warn "$0: option '$OPTARG' requires a value"
                        err "$USAGESTR"
                        ;;
                \?)     err "$USAGESTR"
                        ;;
        esac
done
shift $(( $OPTIND - 1 ))

[[ -z "$STATUS" && ( -n "$ENABLED" && -n "$DISABLED" || -z "$ENABLED" && -z "$DISABLED" ) ]] && err "$USAGESTR"

if [[ -n "$ENABLED" ]] ; then
   SWE=$($APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='dis.metrics.stream-writer.enabled'")
   if [[ -z "$SWE" ]] ; then	# need to insert fresh rows
      HA/mysqlclient.sh -c <<< "insert into global_configuration_cluster (name,description,value,updateable,scope) values ('dis.metrics.stream-writer.enabled',' ','true','1','local')"
      HA/mysqlclient.sh -c <<< "insert into global_configuration_cluster (name,description,value,updateable,scope) values ('dis.metrics.stream-writer.threads',' ','$NUM_THREADS','1','local')"
      HA/mysqlclient.sh -c <<< "insert into global_configuration_cluster (name,description,value,updateable,scope) values ('dis.metrics.stream-writer.batchsize',' ','$BATCHSZ','1','local')"
   else				# can update existing row
      $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "update global_configuration_cluster set value = 'true' where name = 'dis.metrics.stream-writer.enabled'"
      $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "update global_configuration_cluster set value = '$NUM_THREADS' where name = 'dis.metrics.stream-writer.threads'"
      $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "update global_configuration_cluster set value = '$BATCHSZ' where name = 'dis.metrics.stream-writer.batchsize'"
   fi
   $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "update global_configuration_cluster set value = '$NUM_THREADS' where name = 'write.thread.count'"
elif [[ -n "$DISABLED" ]] ; then
   $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "update global_configuration_cluster set value = 'false' where name = 'dis.metrics.stream-writer.enabled'"
   $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "update global_configuration_cluster set value = '4' where name = 'write.thread.count'"
   $APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "update global_configuration_cluster set value = '10000' where name = 'dis.metrics.stream-writer.batchsize'"
fi

if [[ -n "$STATUS" ]] ; then
   SWE=$($APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='dis.metrics.stream-writer.enabled'")
   SWT=$($APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='dis.metrics.stream-writer.threads'")
   SWB=$($APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='dis.metrics.stream-writer.batchsize'")
   WTC=$($APPD_ROOT/HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name='write.thread.count'")
   echo "dis.metrics.stream-writer.enabled=${SWE:-false}"
   echo "dis.metrics.stream-writer.threads=${SWT:-NULL}"
   echo "dis.metrics.stream-writer.batchsize=${SWB:-NULL}"
   echo "write.thread.count=${WTC:-NULL}"
fi
