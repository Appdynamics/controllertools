#!/bin/bash
#
# $Id: threadpoolconfig.sh 1.1 2018-04-17 08:48:31 cmayer
#
# Create thread pools similar to the ones we use on our SaaS controllers
# to dedicate resources to different types of agent requests, and the UI.
#
# specify -n to just print what we are going to do
#
./create_threadpools.sh $@ \
	-t config:8081:30 \
	-t metrics:8082:30 \
	-t status:8083:4 \
	-t agent:8084:30 \
	-t dbmon:8085:30 \
	-t ajax:8086:30 \
	-t analyticsui:8087:14 \
	-t analyticsagent:8088:30 \
	-t universalagent:8093:16 \
	-t restapi:8095:16 \
	-t entitysearch:8096:2
