#!/bin/bash
#
# this script takes an inventory of the controller data, and projects
# the disk space usage by the partitioned tables.   it assumes that
# the controller has a full complement of partitions.  this is unlikely
# for a freshly installed controller
#
# edit this path to point at the controller data directory
CONTROLLER_ROOT=/appdyn/controller
cd $CONTROLLER_ROOT

if [ -x HA/mysqlclient.sh ] ; then
	MYSQL=HA/mysqlclient.sh
else
	MYSQL="bin/controller.sh login-db"
fi

eval `echo "select name,value from global_configuration where name like '%retention%';" | 
	$MYSQL |
	awk '
	/metrics.min.retention.period/ { printf("MIN=%d\n",6*$2); }
	/metrics.ten.min.retention.period/ { printf("TEN=%d\n",$2/2); }
	/metrics.retention.period/ { printf("HOUR=%d\n",$2); }
	/snapshots.retention.period/ { printf("SNAP=%d\n", $2); }
	/tss.retention.period/ { printf("TSS=%d\n", $2); }
	/machine.snapshots.retention.period/ { printf("MSNAP=%d\n", $2); }
	/events.retention.period/ { printf("EVENT=%d\n", $2); }
'`
echo "retention settings from database"
echo ten: $TEN
echo min: $MIN
echo hour: $HOUR
echo snap: $SNAP
echo tss: $TSS
echo msnap: $MSNAP
echo event: $EVENT

DATADIR=`grep ^datadir $CONTROLLER_ROOT/db/db.cnf | cut -d = -f 2`
cd $DATADIR/controller
ls -l *PART*.ibd | awk -v SNAP=$SNAP -v HOUR=$HOUR -v MIN=$MIN -v TEN=$TEN -v TSS=$TSS -v EVENT=$EVENT -v MSNAP=$MSNAP '
	function units(amt) {
		scale = 1;
		while (amt > 1000) { scale += 1; amt /= 1000; }
		return sprintf("%.3f%c", amt, substr(" KMGT",scale,1));
	}
	function high(hw, val) {
		if (val > hw) { return val; } else { return hw; }
	} 
	function process() {
		split($9,t,"#"); 
		table = t[1]; 

		if (table ~ "metricdata_min") group = "minute";	
		else if (table ~ "metricdata_ten_min") group =  "ten_min";	
		else if (table ~ "metricdata_hour") group = "hourly";	
		else if (table ~ "machine_snapshot") group = "machine snapshot";	
		else if (table ~ "eventdata") group = "event";	
		else if (table ~ "requestdata") group = "snapshot";
		else if (table ~ "process_snapshot") group = "process snapshot";
		else if (table ~ "top_summary") group = "tss";
		else print($table);

		split(t[3],p,"."); 
		part = p[1];
		sp = $5;

		tg[table] = group;						# group for table
		gs[group] += sp;						# space for group
		ts[table] += sp;						# space for table
		hw[table] = high(hw[table], sp);		# high water for table
		tc[table]++;							# count of table
		return 0;
	}

	/PART[0-9]/ { 
		misc += process();
	} 
	END {
		pc["minute"]=MIN;
		pc["ten_min"]=TEN;
		pc["hourly"]=HOUR;
		pc["snapshot"]=SNAP;
		pc["machine snapshot"]=MSNAP;
		pc["process snapshot"]=SNAP;
		pc["event"]=EVENT;
		pc["tss"]=TSS;

		# every table
		for (i in ts) {
			subpart = 1;
			if (i == "metricdata_min" || i == "metricdata_ten_min") subpart = 4;
			group = tg[i];
			usage += ts[i];
			proj = hw[i] * pc[group] * subpart;
			gp[group] += proj;
			gt += proj;

			printf("%s(%s): partitions %d(%d) max %s size %s projection %s\n", 
				i, group, tc[i] / subpart, pc[group], units(hw[i]), units(ts[i]), units(proj));
		}
		printf("-------\n");
		for (i in gs) {
			printf("%s: partitions %d current %s projection %s\n",
				i, pc[i], units(gs[i]), units(gp[i]));
		}
		printf("total: %s projected: %s\n", units(usage), units(gt));
	}
	'
