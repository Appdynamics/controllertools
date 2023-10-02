#!/usr/bin/env bash
#
# change compact row format tables to dynamic row format
#
# let's make sure we can do sql first
#
if [ ! -f ../db/.rootpw ] ; then
	echo "please put the root db password in <controller>/db/.rootpw"
	exit
fi

MYSQL=../db/bin/mysql
CONNECT="--protocol=tcp -h localhost -P 3388 -u root --password=$(cat ../db/.rootpw)"

#
# worker for actually running mysql
#
function mysql
{
	$MYSQL $CONNECT -A -B -N controller 2>/dev/null
}

#
# change the row format
#
function dynamic
{
    table=$1

    echo "alter table $table row_format = dynamic;"
    echo "alter table $table row_format = dynamic;" | mysql
}

#
# enumerate all the tables that will get us in trouble
#
mapfile -t tables < <(echo "select concat(t.table_schema,'.',t.table_name) from information_schema.tables t, information_schema.partitions p where t.table_name = p.table_name and t.table_schema = p.table_schema and p.partition_name is null and row_format = 'Compact' order by t.table_rows desc;" | mysql)

for t in ${tables[@]} ; do
	dynamic $t
done
