[ EC install of controller - CLI & Benchmark setup ]
====================================================
# Linux limits setup + ssh setup + user+group setup
# install EC # root
- cd <ec install>
- export VERSION=$(find . -name controller-large.groovy | awk -F/ '{for (i = 0; i < NF; ++i) { if ($i ~ /^[0-9]+\.[0-9]+/) { print $i } }}')
- ./platform-admin/bin/platform-admin.sh login --user-name admin
- ./platform-admin/bin/platform-admin.sh create-platform --name test --installation-dir /opt/appdynamics/platform/$VERSION/product
- ./platform-admin/bin/platform-admin.sh add-hosts --hosts localhost
# edit ./platform-admin/archives/controller/$VERSION*/playbooks/controller-large.groovy # controller_min_ram_in_mb and controller_data_min_disk_space_in_mb
- export PASSWD=
- ./platform-admin/bin/platform-admin.sh submit-job --platform-name test --service controller --job install --args controllerPrimaryHost=cs-lab-02.corp.appdynamics.com controllerAdminUsername=admin controllerAdminPassword=$PASSWD controllerRootUserPassword=$PASSWD mysqlRootPassword=$PASSWD controllerProfile=large
#
( cp ../db.cnf db; cp ../domain.xml ./appserver/glassfish/domains/domain1/config; cp ../license.lic .; cp ../logging.properties ./appserver/glassfish/domains/domain1/config; )
scp ~/scripts/macro_expand.pl lab2:/tmp
ssh lab2; cd <controller install>
cp ./db/db.cnf ./db/db.cnf.$(date +%s)
perl /tmp/macro_expand.pl < /opt/appdynamics/db.cnf.template -l APPD_ROOT=$(pwd) > ./db/db.cnf
cp ./appserver/glassfish/domains/domain1/config/domain.xml ./appserver/glassfish/domains/domain1/config/domain.xml.$(date +%s)
perl /tmp/macro_expand.pl < /opt/appdynamics/domain.xml.template -l APPD_ROOT=$(pwd) > ./appserver/glassfish/domains/domain1/config/domain.xml
#
- ./platform-admin/bin/platform-admin.sh remove-dead-hosts --platform-name test --hosts cs-lab-02.corp.appdynamics.com
- ./platform-admin/bin/platform-admin.sh delete-platform --name test
#
- diff db/db.cnf*
6d5
< malloc-lib=/usr/lib64/libjemalloc.so.1
23,24c22
< tmpdir=/opt/nvme/mysql/tmpdir
< internal_tmp_disk_storage_engine=MYISAM
---
> tmpdir=/opt/appdynamics/platform/4.5.14/product/controller/db/data
36c34
< 
---
> #innodb_flush_method=
69c67
< innodb_checksum_algorithm=crc32
---
> innodb_checksum_algorithm=none
72c70
< innodb_io_capacity = 20000  # 100 per disk
---
> innodb_io_capacity = 9600  # 100 per disk
95c93
< innodb_log_group_home_dir=/opt/nvme/mysql/logs
---
> #innodb_log_group_home_dir=put this on SSD or seperate disk
150d147
< log_timestamps=SYSTEM
ALSO:
83c83
< innodb_buffer_pool_instances=64
---
> innodb_buffer_pool_instances=16
90c90
< innodb_log_file_size=20240M
---
> innodb_log_file_size=10240M
141c141
< innodb_max_dirty_pages_pct=40
---
> innodb_max_dirty_pages_pct=20
#
#
https://confluence.corp.appdynamics.com/display/OPS/How+to%3A+CreateThread+Pools
bash ./appserver/bin/asadmin set server.monitoring-service.module-monitoring-levels.http-service=HIGH
bash ./appserver/bin/asadmin set server.monitoring-service.module-monitoring-levels.thread-pool=HIGH
# diff domain.xml <installed domain.xml>:
91c91
<         <virtual-server default-web-module="controller#controller-web.war" network-listeners="http-listener-1, http-listener-2, http-listener-3" id="server">
---
>         <virtual-server default-web-module="controller#controller-web.war" network-listeners="http-listener-1, http-listener-2" id="server">
307d302
<           <network-listener protocol="http-listener-1" port="8091" name="http-listener-3" thread-pool="http-thread-pool2" transport="tcp"></network-listener>
316,318c311,312
<         <thread-pool name="http-thread-pool" min-thread-pool-size="280" max-thread-pool-size="280" max-queue-size="-1"></thread-pool>
<         <thread-pool name="http-thread-pool2" min-thread-pool-size="280" max-thread-pool-size="280" max-queue-size="-1"></thread-pool>
---
>         <thread-pool name="http-thread-pool" min-thread-pool-size="16" max-thread-pool-size="32"></thread-pool>

########
[ firewall updates ]
iptables -nvL > /tmp/i.1 
./db/bin/mysql --host=lab2 --port=3388 --protocol=TCP --user=impossible
iptables -nvL > /tmp/i.2
diff /tmp/i.1 /tmp/i.2    # see which rules have thrown away packets
iptables -nvL --line-numbers > /tmp/i.3
lab1: iptables-save > /var/tmp/iptables; iptables -I INPUT 6 -s 10.0.225.62 -j ACCEPT
lab2: iptables-save > /var/tmp/iptables; iptables -I INPUT 7 -s 10.0.224.103 -j ACCEPT
####
# cat /etc/security/limits.d/app*
appdyn  hard  nproc 100000
appdyn  soft  nproc 100000
appdyn  soft  nofile 256000
appdyn  hard  nofile 256000
#####
HA/mysqlclient.sh -c <<< "update global_configuration_cluster set value='1000' where name='metrics.buffer.size'"

#####
[ logging.properties for new ingest ]
com.appdynamics.dis.metrics.mysql.stream.level=FINE
Application Infrastructure Performance|App Server|Custom Metrics|Relay|MySQL|Total Rows Inserted|default
Application Infrastructure Performance|App Server|Custom Metrics|Ingestion|Requests|AuthPassed|Metrics Uploaded|default
Application Infrastructure Performance|App Server|Custom Metrics|Relay|MySQL|Total Flush Time|default
#####
[ kernel + network configs ]
lab1 (server): 
#   sysctl -w net.core.netdev_budget=600
#   ifconfig bond0 txqueuelen 2000
#   ifconfig em1 txqueuelen 2000
sysctl -w vm.dirty_ratio=15
sysctl -w vm.dirty_background_ratio=3
sysctl -w vm.dirty_writeback_centisecs=100
sysctl -w vm.dirty_expire_centisecs=500

lab2 (client):; 
#   sysctl -w net.ipv4.ip_local_port_range="1024 65000"
#   sysctl -w net.ipv4.tcp_fin_timeout=30

######
git clone https://github.com/Appdynamics/Metric_Saturation_Test.git
cd Metric_Saturation_Test; make clean; make 
######
- provision and install SDK enabled license.lic on both HA servers
######
$ cat controller-info.xml
<?xml version="1.0" encoding="UTF-8"?>
<controller-info>
        <controller-host>qward.saas.appdynamics.com</controller-host>
            <controller-port>443</controller-port>
            <controller-ssl-enabled>true</controller-ssl-enabled>
        <enable-orchestration>true</enable-orchestration>
        <account-name>appdynamics</account-name>
            <account-access-key>bb6604c1-fbe0-400a-a76b-87c26254fe5e</account-access-key>
                           <application-name>oa</application-name>
           <tier-name>App Server</tier-name>
                <node-name>oacontr1c</node-name>
        <force-agent-registration>false</force-agent-registration>
</controller-info>
#./setmonitor.sh -m url=https://qward.saas.appdynamics.com:443,access_key=bb6604c1-fbe0-400a-a76b-87c26254fe5e,account_name=appdynamics,app_name=saturation_test,tier_name="App Server"
$ cat controller-info.xml
<?xml version="1.0" encoding="UTF-8"?>
<controller-info>
        <controller-host>oa.saas.appdynamics.com</controller-host>
            <controller-port>443</controller-port>
            <controller-ssl-enabled>true</controller-ssl-enabled>
        <enable-orchestration>true</enable-orchestration>
        <account-name>appdynamics</account-name>
            <account-access-key>bb6604c1-fbe0-400a-a76b-87c26254fe5e</account-access-key>
                           <application-name>paid102</application-name>
           <tier-name>App Server</tier-name>
                <node-name>prdcontr102a</node-name>
        <force-agent-registration>false</force-agent-registration>
</controller-info>
./setmonitor.sh -m url=https://oa.saas.appdynamics.com:443,access_key=bb6604c1-fbe0-400a-a76b-87c26254fe5e,account_name=appdynamics,app_name=saturation_test1,tier_name="App Server"
######
com.appdynamics.dis.metrics.mysql.stream.level=FINE
######
ps -T -u appdyn | fgrep -c saturation ; ps -u appdyn | fgrep -c sat

[ Controller upgrade for Benchmark ]
====================================
1 echo 'com.appdynamics.dis.metrics.mysql.stream.level=FINE' >> ./appserver/glassfish/domains/domain1/config/logging.properties
2 check license.lic expiry else re-provision and copy to both servers; ensure you provision 5+ of 'C/C++ SDK APM' - had to uncheck 'Use 4.3 Version of APM Any Language Product?'; Can check under: http://localhost:9000/controller/admin.jsp#/location=ADMIN_ACCOUNT_LIST
3 ./setmonitor.sh -s lab1 -m url=https://oa.saas.appdynamics.com:443/controller,access_key=bb6604c1-fbe0-400a-a76b-87c26254fe5e,account_name=appdynamics,app_name=saturation_test1,tier_name="App Server" -a /opt/appdynamics/platform/4.5.17/product/machine-agent
4 sometimes need to drop Application to avoid 'Application level Metric registration limit reached': application.metric.registration.limit & other mds_configuration limits
5 HA/mysqlclient.sh -c <<< "update global_configuration_cluster set value='1000' where name='metrics.buffer.size'" ; HA/mysqlclient.sh -c <<< "update global_configuration_cluster set value='100000000' where name='application.metric.registration.limit' "
6 cd HA; cp numa.settings.template numa.settings; bash ./numa-patch-controller.sh; cd ../bin; cp numa.settings.template numa.settings
7 cd ..; bash /tmp/streamctl.sh -e 16 -s
8 cd HA; ./replicate.sh ... -F ...
9 get new customer1 access key: 
  - scp $(ls -1tr $(find ~/tweaked_scs/scstool/build/libs -name '*'.jar) | tail -1) lab2:/tmp ; ssh lab2; cd <controller install>
  - SCS=$(HA/mysqlclient.sh -r,-s <<< "select value from global_configuration where name = 'scs.keystore.password'")
  - CIPHER=$(HA/mysqlclient.sh -r,-s <<< "select access_key from controller.account where id=2 and name='customer1'")
  - JAVA_HOME=$(tail -1 ./appserver/glassfish/config/asenv.conf | awk -F\" '{print $2}')
  - CONTROLLER_AK=$($JAVA_HOME/bin/java -jar /tmp/scs*jar decrypt -filename ./.appd.scskeystore -storepass $SCS -ciphertext $CIPHER)
10 [edit scripts/saturate.sh to include new customer1 global access_key: CONTROLLER_AK=96260239-fce6-40b7-805f-3c6aa32c03dc]
10 scp ~/scripts/saturate.sh lab1:/tmp; ssh lab1
11 export PSat=<OA passwd>
12 export LPSat=<controller's admin passwd>
13 bash /tmp/saturate.sh -k $CONTROLLER_AK -h lab2 -m 4000 -b 5000000 -i 1000000 -s 12 -C <controller install> -d

