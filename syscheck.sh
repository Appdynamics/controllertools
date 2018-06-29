#!/bin/bash
#
# run this on a controller machine to look for misconfigurations
#
#
mysqlpid=$(pgrep -x mysqld)
#
# check limits
#
cat /proc/$mysqlpid/limits | awk '
/open files/ { 
	if ($4 < 100000) { 
		printf("not enough open files = %d\n", $4); 
	}
}
/processes/ { 
	if ($3 < 8192) { 
		printf("not enough processes = %d\n", $3); 
	}
}
'
#
# check swap space
#
free -m | awk ' 
/Swap/ {
	if ($2 < 10000) {
		printf("not enough swap space = %d\n", $2);
	}
	if ($4 < 4000) {
		printf("not enough free swap space = %d\n", $4);
	}
}
'

