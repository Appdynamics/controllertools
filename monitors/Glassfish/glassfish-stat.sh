#!/usr/bin/env bash
#
# 14 Jun 2021 cmm
#
# modified from the Appdynamics SaaS glassfish monitor to add:
# enable and disable suffixes to tell glassfish to start/stop thread monitoring
# removed jms
#
PATH=$PATH:/bin:/usr/sbin:/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
CONTROLLER_HOME=/opt/appdynamics/controller
PASSWORD_FILE=$CONTROLLER_HOME/.passwordfile

if [ ! -e $CONTROLLER_HOME/appserver/glassfish/bin/asadmin ] ; then
	exit 2
fi

ASADMIN="/$CONTROLLER_HOME/appserver/glassfish/bin/asadmin  --passwordfile $PASSWORD_FILE"
 
level=""
case "$1" in 
	enable)
		level=HIGH
	;;
	disable)
		level=OFF
	;;
	*)
	;;
esac

if [ -n "$level" ] ; then
	$ASADMIN set server.monitoring-service.module-monitoring-levels.jdbc-connection-pool=$level
	$ASADMIN set server.monitoring-service.module-monitoring-levels.http-service=$level
	exit 1
fi
 
while [ 1 ]; do
	NEXTSECONDS=`date +%s | awk '{print $1 + 18}'`
 
	$ASADMIN get --monitor "server.network.*listener*|server.resources.controller_mysql_pool*" | awk '
		function metric(name) {
			val = $3;
			printf("name=Custom Metrics|%s,aggregator=OBSERVATION,value=%d\n", name, val < 0 ? 0 : val);
			next;
		}
		function poolmetric(name) {
			split($1, n, ".");
			metric("Thread Pool|" n[3] "|" name);
		}
		function mysqlmetric(name) {
			metric("MySQL Connection Pool|" name);
		}
		/server.network.*maxthreads-count/ { poolmetric("Max"); }
        /server.network.*currentthreadsbusy-count/ { poolmetric("Busy"); }
        /server.network.*currentthreadcount-count/ { poolmetric("Current"); }

        /server.network.*connection-queue.countopenconnections-count/ { poolmetric("Connection-Queue|Active"); }
        /server.network.*connection-queue.countqueued-count/ { poolmetric("Connection-Queue|Queued"); }
        /server.network.*connection-queue.maxqueued-count/ { poolmetric("Connection-Queue|Max"); }

        /server.network.*keep-alive.countconnections-count/ { poolmetric("Keep-Alive|Current"); }
        /server.network.*keep-alive.maxrequests-count/ { poolmetric("Keep-Alive|Max"); }
        /server.network.*keep-alive.secondstimeouts-count/ { poolmetric("Keep-Alive|Timeout"); }
		/server.network/ { next; }

		/server.resources.controller_mysql_pool.numconnused-current/ { mysqlmetric("Used"); }
		/server.resources.controller_mysql_pool.numconnfree-current/ { mysqlmetric("Free"); }
		/server.resources.controller_mysql_pool.numconncreated-count/ { mysqlmetric("Created"); }
		/server.resources.controller_mysql_pool.numconndestroyed-count/ { mysqlmetric("Destroyed"); }
		/server.resources.controller_mysql_pool.numconntimedout-count/ { mysqlmetric("Timed Out"); }
		/server.resources.controller_mysql_pool.numconnacquired-count/ { mysqlmetric("Acquired"); }
		/server.resources.controller_mysql_pool.numconnreleased-count/ { mysqlmetric("Released"); }

		/server.resources.controller_mysql_pool.numpotentialconnleak-count/ { mysqlmetric("Potential Leak"); }

		/server.resources.controller_mysql_pool.averageconnwaittime-count/ { mysqlmetric("Average Wait Time"); }

		/server.resources.controller_mysql_pool.waitqueuelength-count/ { mysqlmetric("Wait Queue Max"); }
		/server.resources.controller_mysql_pool.waitqueuelength-current/ { mysqlmetric("Wait Queue Length"); }

		/server.resources.controller_mysql_pool.activeworkcount-current/ { mysqlmetric("Active"); }
		/server.resources.controller_mysql_pool.completedworkcount-current/ { mysqlmetric("Completed"); }
		/server.resources.controller_mysql_pool.rejectedworkcount-current/ { mysqlmetric("Rejected"); }
		/server.resources.controller_mysql_pool.submittedworkcount-current/ { mysqlmetric("Submitted"); }

		/server.resources.controller_mysql_pool.workrequestwaittime-current/ { mysqlmetric("Work Wait Time"); }
	'
 
	SLEEPTIME=`date +"$NEXTSECONDS %s" | awk '{if ($1 > $2) print $1 - $2; else print 0;}'`
	sleep $SLEEPTIME
done
