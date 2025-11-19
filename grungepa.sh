#!/bin/bash
#
# $Id: grungepa.sh 1.0 2025-11-13 18:18:08 cm68
#
# program to grunge through an enterprise console database and print out various scale-related properties from the JVM and 
# database configurations
#
# this knows about glassfish and jetty, and normalizes the representation
#
# the following properties need to be customized to contain the plaintext password of the platform admin database, and the root directory
# of the platform admin

dbpasswd=root
PLATFORM_ROOT=/opt/appdynamics/platform

dbport=3377
MYSQL="$PLATFORM_ROOT/mysql/bin/mysql -BE --protocol=TCP --user=root --port=$dbport --host=localhost --password=$dbpasswd platform_admin"

#
# list of interesting db.cnf settings
#
DELIM=''
for interesting_db in innodb_buffer_pool_size innodb_buffer_pool_instances innodb_buffer_pool_size innodb_flush_method \
	innodb_io_capacity innodb_log_file_size innodb_open_files innodb_io_capacity wait_timeout max_heap_table_size open-files-limit tmp_table_size \
	; do
	DB_FILTER=$DB_FILTER$DELIM^$interesting_db
	DELIM='|'
done

#
# list of uninteresting -X jvm settings
#
DELIM=''
JVM_FILTER='('
for uninteresting_jvm in LogVMOutput UnlockDiagnosticVMOptions UseCompressedOops OmitStackTraceInFastThrow ReservedCodeCacheSize DisableExplicitGC HeapDump \
	; do
	JVM_FILTER=$JVM_FILTER$DELIM$uninteresting_jvm
	DELIM='|'
done
JVM_FILTER=$JVM_FILTER')'

#
# sql executorwrapper function
#
function sql {
	local tmpfile

	mypid=$$
	tmpfile=/tmp/sql_result.$mypid
	errfile=/tmp/sql_error.$mypid
	DELFILES="$tmpfile $errfile"
	rm -f $tmpfile

	if echo "$1" | $MYSQL 2>$errfile >$tmpfile ; then
		cat $tmpfile
		rm -f $tmpfile
	else
		echo 1>&2 cannot connect to platform admin database at port $dbport using password $dbpasswd
		cat 1>&2 $errfile
		exit 1
	fi
}

#
# read a column from sql return
#
function get {
	local key=$1
	#awk "/^[ \t]*$key:/ {k = $0; printf(\"\\\"\"); for (i = 2; i < length; i++) { print \$i } ; printf(\"\\\"\n\") }"
	awk "/^[ \t]*$key:/ {\$1=\"\"; print substr(\$0, 2)}"
}

#
# validate that we can connect to platform admin mysql instance
#
if ! sql 'show databases' > /dev/null ; then
	exit 1
fi

#
# build list of platforms
#
readarray -t platforms < <(sql 'select name from platform' | get name)

for platform in "${platforms[@]}" ; do
	platform_id=$(sql "select id from platform where name = \"$platform\"" | get id)
	controller_id=$(sql "select id from cluster where platform_id = $platform_id and type = \"controller\"" | get id)
	if [ -z $controller_id ] ; then
		continue;
	fi
	jetty=$(sql "select id from configuration_store where property_key = 'jvmStartupConfig' and entity_id = $controller_id" | get id)
	gf=$(sql "select id from configuration_store where property_key = 'controllerNonHostJvmOptions' and entity_id = $controller_id" | get id)
	if [ "$jetty" ] ; then
		echo $platform : jetty
		id=$jetty
		gc=$(sql "select id from configuration_store where property_key = 'gcConfig' and entity_id = $controller_id" | get id)
		if [ "$gc" ] ; then
			id="$id, $gc"
		fi
	elif [ "$gf" ] ; then
		id=$gf
		echo $platform : glassfish
	else
		continue
	fi
	sql "select property_value from configuration_store where id in ($id)" | 
		sed -e 's/^[ ]*property_value: \["//' -e 's/, /\n/g' -e 's/\\n/\n/g' | grep '^-X' |
		egrep -v $JVM_FILTER
	sql "select property_value from configuration_store where property_key = 'mysqlCnfContent' and entity_id = $controller_id" | 
		sed -e 's/^[ ]*property_value: \["//' -e 's/"]$//' -e 's/\\n/\n/g' | sed -e 's/#.*$//' | sed '/^$/d' | awk 'go;/^\[mysqld\]/{go=1}' | sort |
		egrep $DB_FILTER
	echo "--------------------------------------------------"
done
exit 0
