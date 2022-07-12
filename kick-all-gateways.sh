#!/bin/bash

#
# Name: kick-all-gateways.sh
#
# Function:
#	Scan all gateways, restarting if dead.
#

PNAME="$(basename "$0")"
PPATH="$(dirname "$0")"

if [ ! -x "$PPATH/live-gateways.sh" ]; then
	echo "Can't find live-gateways.sh" 1>&2
	exit 1
fi

# output to terminal, but only if verbose.
function _verbose {
	if [[ $OPTVERBOSE -ne 0 ]]; then
		echo "$PNAME:" "$@" 1>&2
	fi
}

# produce the help message.
function _help {
	more 1>&2 <<.

Name:	$PNAME

Function:
	Check all running gateways, and try to fix problems.

Usage:
	$USAGE

Operation:
	The arguments after the options are taken as awk patterns, and
	are compared to the login names of gateways that are currently
	attached. If any pattern matches, then the operation is applied
	to the corresponding gateway. If no patterns are given, all gateways
	are selected.

Options:
	-h		displays help (this message), and exits.

	-v		talk about what we're doing.

	-D		operate in debug mode.

	-B		force a reboot problem on all matching gateways.

	-L		list the descriptions of each gateway.

	-Q		query only, don't try to fix problems.

	-r		always restart the packet forwarder (as a minimum)

	-R		reboot the gateway (as a minimum if any problems are seen)

	-s		display stats

	-f {sep}	separator string between fields, default ': '.
.
}

#### argument scanning:  usage ####
USAGE="${PNAME} -[DhBLQRrsv f*] [pattern ...]"

typeset -i OPTDEBUG=0
typeset -i OPTVERBOSE=0
typeset -i OPTBOOT=0
typeset -i OPTQUERY=0
typeset -i OPTRESTART=0
typeset -i OPTREBOOT=0
typeset -i OPTSTATS=0
typeset -i OPTLISTNAME=0
OPTSEP=": "

typeset -i NEXTBOOL=1
while getopts Df:nBhLQrRsv c
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
	f)	OPTSEP="$OPTARG";;
	B)	OPTBOOT=$NEXTBOOL;;
	h)	_help
		exit 0
		;;
	L)	OPTLISTNAME=$NEXTBOOL;;
	n)	NEXTBOOL=-1;;
	Q)	OPTQUERY=$NEXTBOOL;;
	r)	OPTRESTART=$NEXTBOOL;;
	R)	OPTREBOOT=$NEXTBOOL;;
	s)	OPTSTATS=$NEXTBOOL;;
	v)	OPTVERBOSE=$NEXTBOOL;;
	\?)	echo "$USAGE"
		exit 1;;
	esac
done

#### get rid of scanned options ####
shift $((OPTIND - 1))

### _kickgateway {id} {port}
### kick the gateway on the specified port according
### to the options.
function _kickgateway {
	local -r id="$1"
	local -r p="$2"
	printf "%s" "$id${OPTSEP}$p${OPTSEP}"
	ssh </dev/null -o BatchMode=yes -p "$p" root@localhost \
		'EUI=`mts-io-sysfs show lora/eui`
		FSPCT=$(df -P /var/log/. | tail -1 | awk '\''{ print substr($5, 1, length($5)-1); }'\'')
		MLINUX="$(head -1 /etc/mlinux-version)"
		OPTQUERY='"$OPTQUERY"'
		OPTBOOT='"$OPTBOOT"'
		OPTRESTART='"$OPTRESTART"'
		OPTREBOOT='"$OPTREBOOT"'
		OPTSEP="'"${OPTSEP}"'"
		typeset -i OPTSTATS='"$OPTSTATS"'
		typeset -i OPTLISTNAME='"$OPTLISTNAME"'
		
		# get network bytes / day * 31 -- worst case monthly charge
		if [ $OPTSTATS -ne 0 ]; then
			STATS=$(ifconfig eth0 | awk '\''
				BEGIN { getline < "/proc/uptime" ; updays = $1 / 86400 }
				/RX bytes:/ { print(updays, (substr($2,7) + substr($6,7)) / updays * 31 / 1e6) }'\'')
			printf "%s days${OPTSEP}%s MB/mo${OPTSEP}" ${STATS}
		fi

		# get gateway status
		if [ ! -f /var/run/lora-pkt-fwd.pid ]; then
			DEAD="stopped"
		elif kill -0 "$(cat /var/run/lora-pkt-fwd.pid)" 2>/dev/null ; then
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
			# change DEAD to "concentrator" in case the
			# router is just stopping immediately.
			if [ -f /var/log/lora-pkt-fwd.log ]; then
				LASTLINE=$(tail -1 /var/log/lora-pkt-fwd.log)
				if [ "$LASTLINE" = "ERROR: [main] failed to start the concentrator" ]; then
					DEAD="concentrator"
				fi
			fi
		fi

		if [ X"$DEAD" = X ]; then
			# alert on file system percentage
			if [ $FSPCT -gt 75 ]; then
				DEAD="full"
			fi
		fi

		if [ $OPTBOOT -ne 0 ]; then
			if [ X"$DEAD" = X ]; then
				DEAD="reboot-requested"
			fi
		fi

		printf "%s" "$EUI${OPTSEP}"
		printf "%s%s" "$MLINUX" "$OPTSEP"
		if [[ $OPTLISTNAME -ne 0 ]]; then
			DESC=$(grep '\''"description"'\'': /var/config/lora/local_conf.json | cut -d '\''"'\'' -f 4)
			printf "%s" "$DESC${OPTSEP}"
		fi

		if [ X"$DEAD" = X ]; then
			echo "ok (${FSPCT}%)"
			ACTION=none
			if [ $OPTREBOOT -ne 0 ]; then
				ACTION=reboot
			elif [ $OPTRESTART -ne 0 ]; then
				ACTION=restart
			fi
		elif [ $OPTQUERY -ne 0 ]; then
			echo "$DEAD (${FSPCT}%)"
			ACTION=none
		elif [ X"$DEAD" = Xhung ] || [ X"$DEAD" = Xfull ] || [ X"$DEAD" = Xconcentrator ] || [ $OPTREBOOT -ne 0 ] || [ $OPTBOOT -ne 0 ]; then
			echo "$DEAD (${FSPCT}%), rebooting"
			ACTION=reboot
		else
			echo "$DEAD (${FSPCT}%), restarting"
			ACTION=restart
		fi

		case $ACTION in

		reboot)
			reboot
			;;
		restart)
			/etc/init.d/ttn-pkt-forwarder restart
			;;
		none)
			true
			;;

		esac'
}

# generate an awk program that matches any of the patterns given
# as arguments, one pattern per word.
function _genawkpgm {
	for i in "$@" ; do
		# shellcheck disable=2016 # the '$' below is not a substitution.
		echo "$i" |
		  sed -e 's;/;\\/;g' -e 's;.*;$1 ~ /&/ { print };'
	done | LC_ALL=C sort -u
}

### do the work ###
if [ $# -eq 0 ]; then
	# hit all the gateways
	"$PPATH/live-gateways.sh" |
		while read -r id p ; do
			_kickgateway "$id" "$p"
		done
else
	# the parameters are awk patterns; any gateway that matches
	# any pattern will be handed to _kickgateway.
	"$PPATH/live-gateways.sh" |
		awk "$(_genawkpgm "$@")" |
		while read -r id p ; do
			_kickgateway "$id" "$p"
		done
fi

exit 0
