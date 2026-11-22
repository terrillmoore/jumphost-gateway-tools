#!/bin/bash

#
# Name: kick-all-gateways.sh
#
# Function:
#	Scan all gateways, restarting if dead.
#

PNAME="$(basename "$0")"
PPATH="$(dirname "$0")"

# The polling loop needs bash 5.1 or later (wait -n -p). macOS ships
# bash 3.2 as /bin/bash, so if this bash is too old, run the script
# again with a newer bash from PATH or Homebrew. This test must stay
# runnable by bash 3.2.
# shellcheck disable=2016 # expanded by eval and by bash -c.
BASHTEST='[ "${BASH_VERSINFO[0]}" -gt 5 ] ||
	{ [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }'
if ! eval "$BASHTEST"; then
	for b in $(type -ap bash) /opt/homebrew/bin/bash /usr/local/bin/bash; do
		if [ -x "$b" ] && "$b" -c "$BASHTEST" 2>/dev/null; then
			exec "$b" "$0" "$@"
		fi
	done
	echo "$PNAME: needs bash 5.1 or later; this is bash $BASH_VERSION." 1>&2
	echo "$PNAME: on macOS: brew install bash" 1>&2
	exit 1
fi

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

	The selected gateways are polled in parallel, at most {n} at a
	time (see -j). Each gateway's line appears when its poll ends,
	so the order changes from run to run; pipe the output through
	sort for a stable order.

Options:
	-h		displays help (this message), and exits.

	-v		talk about what we're doing.

	-D		operate in debug mode.

	-B		reboot all matching gateways. With -Q, report
			healthy gateways as "reboot-requested" and
			take no action.

	-L		list the descriptions of each gateway.

	-Q		query only; take no action, even with -B, -r
			or -R.

	-r		restart the forwarder even if it is healthy. A
			fault that needs a reboot still reboots.

	-R		reboot every matching gateway, healthy or not.

	-s		display stats: uptime, and traffic on the
			default-route interface. For ethernet, MB per month
			from the rate since boot; for cellular, MB since
			the link last came up, which resets at each
			reconnect.

	-f {sep}	separator string between fields, default ': '.

	-o {format}	output format: text (the default), or json for
			one JSON object per gateway per line (JSON Lines),
			with every field, whatever -s and -L say.

	-j {n}		poll at most {n} gateways at once, default 32.

	-H {host}	reach the gateways through the jumphost {host},
			an ssh destination. The caller needs ssh keys for
			the jumphost and for the gateways. The default is
			$DEFAULTJUMPHOST, unless gateway tunnels end on
			this machine (it is the jumphost).

	-l		reach the gateways through their tunnels on this
			machine, as on the jumphost; the opposite of -H.
.
}

#### argument scanning:  usage ####
USAGE="${PNAME} -[DhBLlQRrsv f* H* j# o*] [pattern ...]"

typeset -i OPTDEBUG=0
typeset -i OPTVERBOSE=0
typeset -i OPTBOOT=0
typeset -i OPTQUERY=0
typeset -i OPTRESTART=0
typeset -i OPTREBOOT=0
typeset -i OPTSTATS=0
typeset -i OPTLISTNAME=0
OPTSEP=": "
OPTFORMAT=text
typeset -i OPTJOBS=32
# the jumphost's ssh destination; empty means this machine is the
# jumphost. Unset until -H or -l gives it.
unset OPTHOST
DEFAULTJUMPHOST=jumphost.ttni.tech

typeset -i NEXTBOOL=1
while getopts Df:H:j:nBhLlo:QrRsv c
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
	H)	OPTHOST="$OPTARG";;
	j)	if [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]]; then
			OPTJOBS="$OPTARG"
		else
			echo "$PNAME: -j needs a positive integer" 1>&2
			exit 1
		fi
		;;
	B)	OPTBOOT=$NEXTBOOL;;
	h)	_help
		exit 0
		;;
	L)	OPTLISTNAME=$NEXTBOOL;;
	l)	OPTHOST=;;
	n)	NEXTBOOL=-1;;
	o)	case "$OPTARG" in
		text|json)	OPTFORMAT="$OPTARG";;
		*)	echo "$PNAME: -o needs text or json" 1>&2
			exit 1
			;;
		esac
		;;
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

# with neither -H nor -l, use this machine if the gateway tunnels
# (as live-gateways.sh finds them) end here, else the default jumphost.
if [ -z "${OPTHOST+set}" ]; then
	if netstat -ln 2>/dev/null | grep -q '::1:20[0-9][0-9][0-9]'; then
		OPTHOST=
	else
		OPTHOST="$DEFAULTJUMPHOST"
	fi
fi

### _kickgateway {id} {port}
### kick the gateway on the specified port according
### to the options.
function _kickgateway {
	local -r id="$1"
	local -r p="$2"
	local raw
	# the timeouts keep a dead tunnel from holding a job slot
	# indefinitely.
	raw=$(ssh </dev/null "${GWSSHOPTS[@]}" \
		-o BatchMode=yes -o StrictHostKeyChecking=no \
		-o ConnectTimeout=20 \
		-o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
		-p "$p" "root@$GWHOST" \
		'EUI=`mts-io-sysfs show lora/eui`
		FSPCT=$(df -P /var/log/. | tail -1 | awk '\''{ print substr($5, 1, length($5)-1); }'\'')
		MLINUX="$(head -1 /etc/mlinux-version)"
		OPTQUERY='"$OPTQUERY"'
		OPTBOOT='"$OPTBOOT"'
		OPTRESTART='"$OPTRESTART"'
		OPTREBOOT='"$OPTREBOOT"'
	
		# gwinfo {key}: print the string value of gateway_conf.{key}
		# from gateway_info.json, written by ttn-multitech-cm with
		# one key per line. Undoes the \" and \\ escapes; leaves
		# \uXXXX as is. Prints nothing if the file or key is missing.
		GWINFO=/var/config/lora/gateway_info.json
		gwinfo() {
			[ -f $GWINFO ] || return 0
			sed -n -e "s/^ *\"$1\": \"\(.*\)\",*\$/\1/p" $GWINFO |
				sed -e "s/\\\\\"/\"/g" -e "s/\\\\\\\\/\\\\/g"
		}

		# find the transport from gateway_info.json; without it,
		# guess from the rc6.d kill scripts.
		case "$(gwinfo transport)" in
			"basic")
				LORA_TRANSPORT="basic_station"
				;;
			"mp")
				LORA_TRANSPORT="packet_forwarder"
				;;
			"")
				if [ -f "/etc/rc6.d/K30lora-basic-station" ]; then
					LORA_TRANSPORT="basic_station"
				elif [ -f "/etc/rc6.d/K30ttn-pkt-forwarder" ]; then
					LORA_TRANSPORT="packet_forwarder"
				else
					LORA_TRANSPORT="unknown"
				fi
				;;
			*)
				LORA_TRANSPORT="unknown"
				;;
		esac
		typeset -r LORA_TRANSPORT

		# forwarder files: from gateway_info.json, else the defaults
		# for the transport.
		PIDFILE=$(gwinfo pidfile)
		LOGFILE=$(gwinfo logfile)
		INITSCRIPT=$(gwinfo initscript)
		case "$LORA_TRANSPORT" in
			"packet_forwarder")
				: ${PIDFILE:=/var/run/lora-pkt-fwd.pid}
				: ${LOGFILE:=/var/log/lora-pkt-fwd.log}
				: ${INITSCRIPT:=/etc/init.d/ttn-pkt-forwarder}
				;;
			"basic_station")
				: ${PIDFILE:=/var/run/lora/station.pid}
				: ${LOGFILE:=/var/log/basic-station.log}
				: ${INITSCRIPT:=/etc/init.d/lora-basic-station}
				;;
		esac

		# the link is the interface the default route uses. Its byte
		# counts start from zero when the interface comes up: at boot
		# for eth0, but at each reconnect for ppp0.
		UPSECS=$(cut -d. -f1 /proc/uptime)
		NETIF=$(ip route show default 2>/dev/null |
			sed -n -e "s/.* dev \([^ ]*\).*/\1/p" | head -1)
		case "$NETIF" in
			"")		LINK=none;;
			eth*)		LINK=ethernet;;
			ppp*|wwan*)	LINK=cellular;;
			*)		LINK="$NETIF";;
		esac
		LINKBYTES=
		if [ -n "$NETIF" ] && [ -d "/sys/class/net/$NETIF" ]; then
			LINKBYTES=$(( $(cat "/sys/class/net/$NETIF/statistics/rx_bytes") + $(cat "/sys/class/net/$NETIF/statistics/tx_bytes") ))
		fi

		# get gateway status. With no transport there is no
		# pid or log file to check.
		if [ "$LORA_TRANSPORT" = "unknown" ]; then
			DEAD="unknown-transport"
		elif [ ! -f "$PIDFILE" ]; then
			DEAD="stopped"
		elif kill -0 "$(cat "$PIDFILE")" 2>/dev/null ; then
			DEAD=
		else
			DEAD="crashed"
		fi

		# a forwarder process not named in the pid file is an
		# orphan. The init script stops only the pid file process,
		# so a restart leaves the orphan holding the radio.
		case "$LORA_TRANSPORT" in
			"packet_forwarder")
				FWDPROGS="mp_pkt_fwd.usb mp_pkt_fwd.spi"
				;;
			"basic_station")
				FWDPROGS="station"
				;;
			*)
				FWDPROGS=
				;;
		esac
		if [ -n "$FWDPROGS" ]; then
			FWDPID=
			[ -f "$PIDFILE" ] && FWDPID=$(cat "$PIDFILE")
			for pid in $(pidof $FWDPROGS); do
				if [ "$pid" != "$FWDPID" ]; then
					DEAD="orphan"
				fi
			done
		fi

		if [ X"$DEAD" = X ]; then
			# set X non-empty if file is more than 10 minutes old
			X=$(find "$LOGFILE" -mmin +10)
			if [ X"$X" != X ]; then
				DEAD="hung"
			fi
		fi

		if [ X"$DEAD" = Xcrashed ]; then
			if [[ "$LORA_TRANSPORT" = "packet_forwarder" ]]; then
				# change DEAD to "concentrator" in case the
				# router is just stopping immediately. The mp
				# forwarder (3.0.25) puts a timestamp before
				# the message, so match the end of the line.
				if [ -f "$LOGFILE" ]; then
					LASTLINE=$(tail -1 "$LOGFILE")
					case "$LASTLINE" in
					*"ERROR: [main] failed to start the concentrator")
						DEAD="concentrator"
						;;
					esac
				fi
			fi
		fi

		if [ X"$DEAD" = X ] || [ X"$DEAD" = Xunknown-transport ]; then
			# alert on file system percentage; a full disk
			# needs a reboot whatever the transport.
			if [ $FSPCT -gt 75 ]; then
				DEAD="full"
			fi
		fi

		if [ $OPTBOOT -ne 0 ]; then
			if [ X"$DEAD" = X ]; then
				DEAD="reboot-requested"
			fi
		fi

		DESC=$(gwinfo description)
		if [ -z "$DESC" ]; then
			case "$LORA_TRANSPORT" in
				"packet_forwarder")
					DESC=$(grep '\''"description"'\'': /var/config/lora/local_conf.json 2>/dev/null | cut -d '\''"'\'' -f 4)
					;;
				"basic_station")
					DESC="unknown (Basic Station)"
					;;
				*)
					DESC="unknown (misconfig)"
					;;
			esac
		fi

		# choose the action. -Q does nothing; an unknown transport
		# has no init script, so only an explicit -R or -B reboots.
		if [ $OPTQUERY -ne 0 ]; then
			ACTION=none
		elif [ X"$DEAD" = X ]; then
			ACTION=none
			if [ $OPTREBOOT -ne 0 ]; then
				ACTION=reboot
			elif [ $OPTRESTART -ne 0 ]; then
				ACTION=restart
			fi
		elif [ X"$DEAD" = Xunknown-transport ]; then
			ACTION=none
			if [ $OPTREBOOT -ne 0 ] || [ $OPTBOOT -ne 0 ]; then
				ACTION=reboot
			fi
		elif [ X"$DEAD" = Xhung ] || [ X"$DEAD" = Xfull ] || [ X"$DEAD" = Xconcentrator ] || [ X"$DEAD" = Xorphan ] || [ $OPTREBOOT -ne 0 ] || [ $OPTBOOT -ne 0 ]; then
			ACTION=reboot
		else
			ACTION=restart
		fi

		# report as "@key=value" lines, ended by "@end"; the jumphost
		# side formats them. Anything printed after "@end" is output
		# from the action.
		echo "@eui=$EUI"
		echo "@mlinux=$MLINUX"
		echo "@description=$DESC"
		echo "@transport=$LORA_TRANSPORT"
		echo "@status=${DEAD:-ok}"
		echo "@fspct=$FSPCT"
		echo "@uptime_secs=$UPSECS"
		echo "@link=$LINK"
		echo "@interface=$NETIF"
		echo "@link_bytes=$LINKBYTES"
		echo "@action=$ACTION"
		echo "@end"

		case $ACTION in

		reboot)
			reboot
			;;
		restart)
			"$INITSCRIPT" restart
			;;
		none)
			true
			;;

		esac' 2>&1)

	_formatgateway "$id" "$p" "$raw"
}

### _jsonstr {string}
### print string as a JSON string; an empty string prints null.
function _jsonstr {
	local s="$1"
	if [ -z "$s" ]; then
		printf 'null'
		return
	fi
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\r'/\\r}"
	s="${s//$'\t'/\\t}"
	# drop any other control characters, which JSON doesn't allow.
	s="$(LC_ALL=C; printf '%s' "${s//[$'\x01'-$'\x1f']/}")"
	printf '"%s"' "$s"
}

### _jsonnum {string}
### print string as a JSON number, or null if it isn't one.
function _jsonnum {
	if [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
		printf '%s' "$1"
	else
		printf 'null'
	fi
}

### _derivestats {array}
### add uptime_days, link_mb and mb_per_month to the associative array
### named, from its uptime_secs, link and link_bytes. link_mb is the
### traffic since the link came up. mb_per_month is the daily rate
### since boot times 31, given only for ethernet: a cellular link's
### counts start again at each reconnect, and nothing on the gateway
### gives a trustworthy time for that. Missing values stay empty.
function _derivestats {
	local -n A="$1"
	local v
	v=$(awk -v up="${A[uptime_secs]}" -v lb="${A[link_bytes]}" \
		-v link="${A[link]}" 'BEGIN {
		printf "%s", (up == "" ? "-" : sprintf("%.6g", up / 86400))
		printf " %s", (lb == "" ? "-" : sprintf("%.6g", lb / 1e6))
		printf " %s\n", (link != "ethernet" || up == "" || lb == "" || up <= 0 ? "-" :
			sprintf("%.6g", lb / up * 86400 * 31 / 1e6))
	}')
	read -r 'A[uptime_days]' 'A[link_mb]' 'A[mb_per_month]' <<<"$v"
	[ "${A[uptime_days]}" = "-" ] && A[uptime_days]=
	[ "${A[link_mb]}" = "-" ] && A[link_mb]=
	[ "${A[mb_per_month]}" = "-" ] && A[mb_per_month]=
	return 0
}

### _formatgateway {id} {port} {raw}
### print the report for one gateway from the raw output of its ssh:
### "@key=value" lines up to "@end", then the action's output. If
### there is no "@end", the ssh failed, and raw is its error text.
function _formatgateway {
	local -r id="$1"
	local -r p="$2"
	local -r raw="$3"
	local -r now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	local -A F=()
	local log=""
	local line
	local -i ended=0
	local out

	while IFS= read -r line; do
		if [ $ended -eq 0 ] && [ "$line" = "@end" ]; then
			ended=1
		elif [ $ended -eq 0 ] && [[ "$line" =~ ^@([a-z_]+)=(.*)$ ]]; then
			F[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
		else
			log+="$line"$'\n'
		fi
	done <<<"$raw"

	if [ $ended -eq 0 ]; then
		if [ "$OPTFORMAT" = json ]; then
			printf '{"login":%s,"port":%s,"time":%s,"error":%s}\n' \
				"$(_jsonstr "$id")" "$(_jsonnum "$p")" \
				"$(_jsonstr "$now")" "$(_jsonstr "${raw%$'\n'}")"
		else
			printf '%s\n' "$id$OPTSEP$p$OPTSEP$raw"
		fi
		return
	fi

	_derivestats F

	if [ "$OPTFORMAT" = json ]; then
		local k
		out='{"login":'"$(_jsonstr "$id")"',"port":'"$(_jsonnum "$p")"
		out+=',"time":'"$(_jsonstr "$now")"
		for k in eui mlinux description transport status action link interface; do
			out+=',"'"$k"'":'"$(_jsonstr "${F[$k]}")"
		done
		for k in fspct uptime_secs uptime_days link_bytes link_mb mb_per_month; do
			out+=',"'"$k"'":'"$(_jsonnum "${F[$k]}")"
		done
		out+=',"output":'"$(_jsonstr "${log%$'\n'}")"'}'
		printf '%s\n' "$out"
		return
	fi

	out="$id$OPTSEP$p$OPTSEP"
	if [ $OPTSTATS -ne 0 ]; then
		out+="${F[uptime_days]} days$OPTSEP"
		if [ -n "${F[mb_per_month]}" ]; then
			out+="${F[mb_per_month]} MB/mo$OPTSEP"
		else
			out+="${F[link_mb]} MB since link up$OPTSEP"
		fi
	fi
	out+="${F[eui]}$OPTSEP${F[mlinux]}$OPTSEP${F[link]}$OPTSEP"
	if [ $OPTLISTNAME -ne 0 ]; then
		out+="${F[description]}$OPTSEP"
	fi
	out+="${F[status]} (${F[fspct]}%)"
	case "${F[action]}" in
	reboot)		out+=", rebooting";;
	restart)	out+=", restarting";;
	esac
	printf '%s\n' "$out"
	printf '%s' "$log"
}

# generate an awk program that matches any of the patterns given
# as arguments, one pattern per word. All patterns go in one rule,
# so a login that matches several is printed once.
function _genawkpgm {
	local sep=""
	local i
	for i in "$@" ; do
		# shellcheck disable=2016 # the '$' below is not a substitution.
		printf '%s$1 ~ /%s/' "$sep" "$(printf '%s\n' "$i" | sed -e 's;/;\\/;g')"
		sep=" || "
	done
	printf ' { print }\n'
}

### _livegateways
### run live-gateways.sh, on the jumphost given by -H if any.
function _livegateways {
	if [ -n "$OPTHOST" ]; then
		ssh "${JHSSHOPTS[@]}" "$OPTHOST" bash -s <"$PPATH/live-gateways.sh"
	else
		"$PPATH/live-gateways.sh"
	fi
}

### _selectgateways [pattern ...]
### print "login port" for each live gateway that matches any of
### the awk patterns, or for every live gateway if there are none.
function _selectgateways {
	if [ $# -eq 0 ]; then
		_livegateways
	else
		_livegateways | awk "$(_genawkpgm "$@")"
	fi
}

### do the work ###

# Poll the gateways in parallel, at most OPTJOBS at a time. Each
# poll writes to its own file, which is printed and removed as soon
# as that poll ends, so one gateway's output is never split by
# another's.
OUTDIR="$(mktemp -d)" || { echo "$PNAME: can't create temp dir" 1>&2 ; exit 1 ; }
trap 'rm -rf "$OUTDIR"' EXIT

# With -H, every ssh to the jumphost, and every poll's connection
# through it, shares one master connection. Separate logins, 32 at
# a time, would hit sshd's MaxStartups limit. Gateway host keys are
# not kept, so the caller's known_hosts gets no entry per gateway.
# Without -H, the gateways' tunnels are on this machine.
JHSSHOPTS=()
GWSSHOPTS=()
GWHOST=localhost
if [ -n "$OPTHOST" ]; then
	JHSSHOPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o ControlPath="$OUTDIR/ssh-ctl")
	if ! ssh "${JHSSHOPTS[@]}" -o ControlMaster=yes -o ControlPersist=no \
		-o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
		-fN "$OPTHOST" ; then
		echo "$PNAME: can't connect to $OPTHOST" 1>&2
		exit 1
	fi
	trap 'ssh "${JHSSHOPTS[@]}" -O exit "$OPTHOST" 2>/dev/null; rm -rf "$OUTDIR"' EXIT
	printf -v PROXYCMD 'ssh -o BatchMode=yes -o ControlPath=%q -W [%%h]:%%p %q' \
		"$OUTDIR/ssh-ctl" "$OPTHOST"
	GWSSHOPTS=(-o ProxyCommand="$PROXYCMD" \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
	# the tunnel listeners are IPv6 only.
	GWHOST=::1
fi

# On ^C or SIGTERM, send SIGTERM to the whole process group, so that
# every poll and its ssh stop even if one ignores SIGINT. This shell
# ignores that SIGTERM, so it can exit and remove OUTDIR.
trap 'trap "" TERM; kill -TERM 0 2>/dev/null; exit 130' INT TERM

# output file of each running poll, by PID.
declare -A JOBFILE

### _reapone
### wait for one poll to end, then print and remove its output file.
### Returns nonzero if no poll is running.
function _reapone {
	local endpid
	local f
	while : ; do
		# -p (bash 5.1) gives the PID that ended. Skip the process
		# substitution that feeds the main loop, which is not a poll.
		wait -n -p endpid
		[ -n "$endpid" ] || return 1
		f="${JOBFILE[$endpid]}"
		[ -n "$f" ] && break
	done
	unset 'JOBFILE[$endpid]'
	cat "$f"
	# a failed ssh leaves the line without a newline.
	if [ -n "$(tail -c 1 "$f")" ]; then
		echo
	fi
	rm -f "$f"
}

typeset -i NGW=0
typeset -i NRUNNING=0
while read -r id p ; do
	if [ $NRUNNING -ge $OPTJOBS ]; then
		_reapone
		NRUNNING=$((NRUNNING - 1))
	fi
	f="$OUTDIR/$(printf '%05d' $NGW)"
	_kickgateway "$id" "$p" >"$f" 2>&1 &
	JOBFILE[$!]="$f"
	NGW=$((NGW + 1))
	NRUNNING=$((NRUNNING + 1))
done < <(_selectgateways "$@")

while [ $NRUNNING -gt 0 ] && _reapone ; do
	NRUNNING=$((NRUNNING - 1))
done

exit 0
