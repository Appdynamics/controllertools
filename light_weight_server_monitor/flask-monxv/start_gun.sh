#!/usr/local/bin/bash

#
# start up monX server processes
#

PROJDIR=flask-monxv

#  err "some message" [optional return code]
function err {
   local exitcode=${2:-1}                               # default to exit 1
   local c=($(caller 0))                                        # who called me?
   local r="${c[2]} (f=${c[1]},l=${c[0]})"                       # where in code?

   echo "ERROR: $r failed: $1" 1>&2
   exit $exitcode
}
function warn {
   echo "WARN: $1" 1>&2
}
function info {
   echo "INFO: $1" 1>&2
}

# need to be outside of $PROJDIR directory for startup to work
[[ -f "$PROJDIR/$(basename $0)" ]] || err "Must start server outside $PROJDIR i.e. cd $PROJDIR/.."

#
# redis-server /usr/local/etc/redis.conf &
#
if [[ -z "$(pgrep -f 'redis-server 127')" ]] ; then
	redis-server /usr/local/etc/redis.conf &
	sleep 1
fi

[[ -n "$(pgrep -f 'redis-server 127')" ]] || err "Unable to start redis-server"
#exec gunicorn -w 2 -b 127.0.0.1:4000 -k gevent --log-file=- --timeout=120 --log-level=debug "flask-monxv:create_app()"
exec gunicorn -w 2 -b 127.0.0.1:4000 -k gevent --log-file=- --timeout=120 --capture-output --log-level=debug "flask-monxv:create_app()"
