#!/bin/bash
#
# $Id: create_threadpools.sh  2018-03-09 14:14:22 cmayer
#
# Create thread pools similar to the ones we use on our SaaS controllers
# to dedicate resources to different types of agent requests, and the UI.
#
# Reference: https://docs.oracle.com/cd/E18930_01/html/821-2433/gentextid-110.html#scrolltoc
# originally by Mike Przybylski
#
CONTROLLER_HOME=/opt/AppDynamics/Controller
cp $CONTROLLER_HOME/appserver/glassfish/domains/domain1/config/domain.xml $CONTROLLER_HOME/domain.xml-pre-add

# used for testing...
#ASADMIN="$CONTROLLER_HOME/appserver/glassfish/bin/asadmin\
ASADMIN="$CONTROLLER_HOME/appserver/glassfish/bin/asadmin\
  --user=admin\
  --passwordfile=$CONTROLLER_HOME/.passwordfile"

TLS_CIPHER_LIST="+TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,+TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,+TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,+TLS_RSA_WITH_AES_256_GCM_SHA384,+TLS_ECDH_ECDSA_WITH_AES_256_GCM_SHA384,+TLS_ECDH_RSA_WITH_AES_256_GCM_SHA384,+TLS_DHE_RSA_WITH_AES_256_GCM_SHA384,+TLS_DHE_DSS_WITH_AES_256_GCM_SHA384,+TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,+TLS_RSA_WITH_AES_128_GCM_SHA256,+TLS_ECDH_ECDSA_WITH_AES_128_GCM_SHA256,+TLS_ECDH_RSA_WITH_AES_128_GCM_SHA256,+TLS_DHE_RSA_WITH_AES_128_GCM_SHA256,+TLS_DHE_DSS_WITH_AES_128_GCM_SHA256,+TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384,+TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384,+TLS_RSA_WITH_AES_256_CBC_SHA256,+TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA384,+TLS_ECDH_RSA_WITH_AES_256_CBC_SHA384,+TLS_DHE_RSA_WITH_AES_256_CBC_SHA256,+TLS_DHE_DSS_WITH_AES_256_CBC_SHA256,+TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA,+TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,+TLS_RSA_WITH_AES_256_CBC_SHA,+TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA,+TLS_ECDH_RSA_WITH_AES_256_CBC_SHA,+TLS_DHE_RSA_WITH_AES_256_CBC_SHA,+TLS_DHE_DSS_WITH_AES_256_CBC_SHA,+TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256,+TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256,+TLS_RSA_WITH_AES_128_CBC_SHA256,+TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA256,+TLS_ECDH_RSA_WITH_AES_128_CBC_SHA256,+TLS_DHE_RSA_WITH_AES_128_CBC_SHA256,+TLS_DHE_DSS_WITH_AES_128_CBC_SHA256,+TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA,+TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,+TLS_RSA_WITH_AES_128_CBC_SHA,+TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA,+TLS_ECDH_RSA_WITH_AES_128_CBC_SHA,+TLS_DHE_RSA_WITH_AES_128_CBC_SHA,+TLS_DHE_DSS_WITH_AES_128_CBC_SHA,+TLS_EMPTY_RENEGOTIATION_INFO_SCSV"

function change_port() { # name port
	echo "change port $1 to $2"
	$ASADMIN set server.network-config.network-listeners.network-listener.$1.port="$2" 
}

function create_ssl() {	# name
	echo "adding ssl to $1"

	$ASADMIN create-ssl --type http-listener --certname s1as --ssl3enabled false --tlsenabled true\
        --ssl3tlsciphers "$TLS_CIPHER_LIST" ${1}-listener
}

function create_threadpool_quartet() { # name port threadcount [ssl] [address]
	echo "creating $1 thread pool on port $2 with $3 threads"

	# create thread pool
	$ASADMIN delete-threadpool ${1}-threadpool
	$ASADMIN create-threadpool --maxthreadpoolsize $3 --minthreadpoolsize $3 --maxqueuesize -1 ${1}-threadpool

    # create transport
	$ASADMIN delete-transport ${1}-tcp
    $ASADMIN create-transport --acceptorthreads 15 --buffersizebytes 32768 --displayconfiguration=true\
        --maxconnectionscount 32768 --classname org.glassfish.grizzly.nio.transport.TCPNIOTransport ${1}-tcp

	$ASADMIN delete-protocol ${1}-protocol
if [ "$4" = ssl ] ; then
	# create protocol
	$ASADMIN create-protocol --securityenabled=true ${1}-protocol
	$ASADMIN create-ssl --type http-listener --certname s1as --ssl3enabled false --tlsenabled true\
        --ssl3tlsciphers "$TLS_CIPHER_LIST" ${1}-listener
else
	$ASADMIN create-protocol ${1}-protocol
fi

	# create HTTP settings to accompany protocol
	$ASADMIN create-http --request-timeout-seconds 66 --timeout-seconds 66 --default-virtual-server server \
        --max-connection -1 --xpowered=false ${1}-protocol

	$ASADMIN delete-network-listener ${1}-listener
    # create network listener 
	if [ -n "$4" ] ; then
		$ASADMIN create-network-listener --address $4 --listenerport $2 --threadpool ${1}-threadpool \
            --protocol ${1}-protocol --transport ${1}-tcp ${1}-listener
	else
		$ASADMIN create-network-listener --listenerport $2 --threadpool ${1}-threadpool \
            --protocol ${1}-protocol --transport ${1}-tcp ${1}-listener
	fi
}

change_port http-listener-1 8079
change_port http-listener-2 4443

create_threadpool_quartet config 8081 30
create_threadpool_quartet metrics 8082 30
create_threadpool_quartet status 8083 4
create_threadpool_quartet agent 8084 30
create_threadpool_quartet dbmon 8085 30
create_threadpool_quartet ajax 8086 30
create_threadpool_quartet analyticsui 8087 14
create_threadpool_quartet analyticsagent 8088 30
create_threadpool_quartet universalagent 8093 16
create_threadpool_quartet restapi 8095 16
create_threadpool_quartet entitysearch 8096 2

echo "All thread pools created successfully. Please restart the controller app server."
