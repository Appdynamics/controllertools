#!/bin/bash
#
# $Id: space_projection.sh  2018-03-09 14:09:50 cmayer
#
# this script takes an inventory of the controller data, and projects
# the disk space usage by the partitioned tables.   it assumes that
# the controller has a full complement of partitions.  this is unlikely
# for a freshly installed controller
#
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd -P)" 

# the usual suspects
CANDIDATES=(
	/appdyn/controller 
	/opt/appdynamics/controller 
	/opt/AppDynamics/controller 
	/opt/AppDynamics/Controller
	~/controller
	~/Controller
	$SCRIPTDIR
	$SCRIPTDIR/..
)

MYSQL=
CONTROLLER_ROOT=

# let's search for a usable controller
for path in $(pwd -P) ${CANDIDATES[*]} ; do
	cd $CONTROLLER_ROOT
	if [ -x $path/HA/mysqlclient.sh ] ; then
		CONTROLLER_ROOT=$path
		MYSQL=$path/HA/mysqlclient.sh
		break
	fi
	if [ -x $path/bin/controller.sh ] ; then
		if [ ! -r $path/db/.rootpw ] ; then
			continue
		fi
		CONTROLLER_ROOT=$path
		MYSQL="$path/bin/controller.sh login-db"
		break
	fi
done

if [ -z $CONTROLLER_ROOT ] ; then
	echo "cannot find controller root: please cd to it"
	exit 1
fi

cd $CONTROLLER_ROOT

if [ ! -r db/.rootpw ] ; then
	echo "this tool requires a readable db/.rootpw"
	exit 1
fi

MIN=0

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

if [ $MIN -eq 0 ] ; then
	echo "could not connect to database"
	exit 1
fi

if false ; then
echo "retention settings from database"
echo ten: $TEN
echo min: $MIN
echo hour: $HOUR
echo snap: $SNAP
echo tss: $TSS
echo msnap: $MSNAP
echo event: $EVENT
fi

DATADIR=`grep ^datadir $CONTROLLER_ROOT/db/db.cnf | cut -d = -f 2`
cd $DATADIR/controller
ls -l *PART*.ibd | gawk -v SNAP=$SNAP -v HOUR=$HOUR -v MIN=$MIN -v TEN=$TEN -v TSS=$TSS -v EVENT=$EVENT -v MSNAP=$MSNAP '
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
		else group = "other";

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

		asorti(ts, tsi);
		for (ti in tsi) { 
			i = tsi[ti] ; 
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
		asorti(gs, gsi);
		for (gi in gsi) {
			i = gsi[gi];
			printf("%s: partitions %d current %s projection %s\n",
				i, pc[i], units(gs[i]), units(gp[i]));
		}
		printf("total: %s projected: %s\n", units(usage), units(gt));
	}
	'
