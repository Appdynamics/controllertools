#--------------------------------------------------------------------------------------------------
 #   AppDynamics controller metadata backup script
#--------------------------------------------------------------------------------------------------
#    This script will perform a metadata backup of the AppDynamics controller database to a
#    file.  The contents of the backup excludes metrics, events, snapshots and summary statistics,
#    which comprise the largest portion of the database.  All other tables, which make up the
#    controller metadata are included in the backup.
#
#	Modifications:
#
#     1) Set or replace $controller_root with the path to the installation directory
#          for AppDynamics.  Alternatively, execute mysqldump from the following directory:
#              [controller_root]/db/bin
#
#     2) Replace [password] with the root password for the AppDynamics controller
#          MySQL database.  This password may have been set at the time of installation.
#
#     3) (Optional) Specify the database port if different from the default 3388.
#
#     4) Set the pathname and file name of the generated SQL dump file into the backup_dest variable
#          line of this script
#
#--------------------------------------------------------------------------------------------------
# VERSION updated for all controllers to automatically generate excludes of partitioned tables
#         also, datadir is extracted from db.cnf file to handle an external database filesystem
# 27 Dec 2020, cmm
#

backup_dest=/opt/appdynamics/backup/dump/appdynamics_metadata_backup.sql

controller_root=/opt/appdynamics/platform/product/controller

if [ ! -x $controller_root/db/bin/mysqldump ] ; then
	if [ -x ./mysqldump ] ; then
		controller_root=$(cd ../.. ; pwd)
	else
		echo "must set controller_root or run from db/bin"
		exit 1
	fi
fi

if [ -z "$password" -a -f $controller_root/db/.rootpw ] ; then
	password=$(cat $controller_root/db/.rootpw)
fi

datadir=$(grep datadir $controller_root/db/db.cnf | sed s/^.*=//)

ignores=""
for table in $(find $datadir -name \*PARTMAX\* -print | sed -e s/#P.*// -e s,.*/,, -e s,/,., | sort -u) ; do 
  ignores="$ignores --ignore-table=controller.$table"
done

databases="controller $(cd $datadir ; ls -d mds* eum* 2>/dev/null)"

$controller_root/db/bin/mysqldump --user=root --password=$password --protocol=TCP --port=3388 \
--databases $databases --skip-add-locks --skip-lock-tables --routines $ignores  \
> $backup_dest

echo metadata backup written to $backup_dest
