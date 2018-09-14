#!/bin/bash

#
# Name: kick-all-gateways.sh
#
# Function:
#	Scan all gateways, restarting if dead.
#

PNAME=$(basename $0)
PPATH=$(dirname $0)

if [ ! -x "$PPATH/live-gateways.sh" ]; then
	echo "Can't find live-gateways.sh" 1>&2
	exit 1
fi

# output to terminal, but only if verbose.
function _verbose {
	if [ $OPTVERBOSE -ne 0 ]; then
		echo "$PNAME:" "$@" 1>&2
	fi
}

# produce the help message.
function _help {
	more 1>&2 <<.

Name:	$PNAME

Function:
	Check all running gateways.

Usage:
	$USAGE

Switches:
	-h		displays help (this message), and exits.

	-v		talk about what we're doing.

	-D		operate in debug mode.

	-Q		query only, don't restart
.
}

#### argument scanning:  usage ####
USAGE="${PNAME} -[DhQv]"

OPTDEBUG=0
OPTVERBOSE=0
OPTQUERY=0

NEXTBOOL=1
while getopts DnhQv c
do
	if [ $NEXTBOOL -eq -1 ]; then
		NEXTBOOL=0
	else
		NEXTBOOL=1
	fi

	if [ $OPTDEBUG -ne 0 ]; then
		echo "Scanning option -${c}" 1>&2
	fi

	case $c in
	D)	OPTDEBUG=$NEXTBOOL;;
	h)	_help
		exit 0
		;;
	n)	NEXTBOOL=-1;;
	Q)	OPTQUERY=$NEXTBOOL;;
	v)	OPTVERBOSE=$NEXTBOOL;;
	\?)	echo "$USAGE"
		exit 1;;
	esac
done

### do the work ###
"$PPATH/live-gateways.sh" |
	while read id p ; do
		echo -n $id "$p: "
		ssh </dev/null -p $p root@localhost \
			'EUI=`mts-io-sysfs show lora/eui`
			FSPCT=$(df -P /var/log/. | tail -1 | awk '\''{ print substr($5, 1, length($5)-1); }'\'')
			OPTQUERY='"$OPTQUERY"'
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

			if [ X"$DEAD" = Xcrashed ]; then
				# change DEAD to hung in case the
				# router is just stopping immediately.
				echo "... check whether we need to reboot"
				if [ -f /var/log/lora-pkt-fwd.log ]; then
					LASTLINE=$(tail -1 /var/log/lora-pkt-fwd.log)
					if [ "$LASTLINE" = "ERROR: [main] failed to start the concentrator" ]; then
						DEAD="concentrator"
					fi
				fi
			fi

			if [ X"$DEAD" = X ]; then
				# alert on file system percentage
				if [ $FSPCT -gt 90 ]; then
					DEAD="full"
				fi
			fi

			if [ X"$DEAD" = X ]; then
				echo "$EUI: ok (${FSPCT}%)"
			elif [ $OPTQUERY -ne 0 ]; then
				echo "$EUI: $DEAD (${FSPCT}%)"
			elif [ X"$DEAD" = Xhung -o X"$DEAD" = Xfull -o X"$DEAD" = Xconcentrator ]; then
				echo "$EUI: $DEAD (${FSPCT}%), rebooting"
				reboot
			else
				echo "$EUI: $DEAD (${FSPCT}%), restarting"
				/etc/init.d/ttn-pkt-forwarder restart
			fi'
	done
