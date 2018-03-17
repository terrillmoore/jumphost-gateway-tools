#!/bin/bash

PPATH=$(dirname $0)

if [ ! -x "$PPATH/live-gateways.sh" ]; then
	echo "Can't find live-gateways.sh" 1>&2
	exit 1
fi

"$PPATH/live-gateways.sh" |
	while read id p ; do
		echo -n $id "$p: "
		ssh </dev/null -p $p root@localhost \
			'EUI=`mts-io-sysfs show lora/eui`
			if [ ! -f /var/run/lora-pkt-fwd.pid ]; then
				DEAD="stopped"
			elif kill -0 `cat /var/run/lora-pkt-fwd.pid` ; then
				DEAD=
			else
				DEAD="crashed"
			fi

			if [ X"$DEAD" = X ]; then
				# set X non-empty if file is more than 10 minutes old
				X=$(find /var/log/lora-pkt-fwd.log -mmin +10)
				if [ X"$X" != X ]; then
					DEAD="hung"
				fi
			fi

			if [ X"$DEAD" = X ]; then
				echo "$EUI: ok"
			else
				echo "$EUI: $DEAD, restarting"
				/etc/init.d/ttn-pkt-forwarder restart
			fi'
	done
