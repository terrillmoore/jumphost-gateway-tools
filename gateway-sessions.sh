#!/bin/bash

#
# Name: gateway-sessions.sh
#
# Function:
#	Show the connect history of gateways, from the session log that
#	gw-session-log writes on the jumphost.
#

PNAME="$(basename "$0")"

DEFAULTJUMPHOST=jumphost.ttni.tech
LOGDIR=/var/log
LOGNAME=gateway-sessions.log

USAGE="$PNAME [-hlr] [-H host] [-S since] [pattern ...]"

function _help {
	more 1>&2 <<.

Name:	$PNAME

Function:
	Show when each gateway's ssh session to the jumphost opened and
	closed.

Usage:
	$USAGE

Operation:
	Reads $LOGDIR/$LOGNAME and its rotated copies on the jumphost.
	The arguments after the options are awk patterns, matched
	against gateway login names; with none, all gateways are shown.

	Output is one line per session, tab-separated: login, port,
	opened, closed, length, remote address. Times are UTC. "up" in
	the closed column means the session is still open; "lost" means
	the log has no close for it and its sshd is gone.

Options:
	-H host	read the log on this jumphost (default $DEFAULTJUMPHOST,
		or this machine if it has the log).
	-l	read the log on this machine.
	-r	print the log lines themselves, not sessions.
	-S since
		start at this time: any prefix of 2026-11-24T16:49:10Z,
		for example 2026-11 or 2026-11-24T16.
	-h	print this help.
.
}

# Runs on the machine that has the log. Arguments: raw (0/1), since,
# then the patterns.
function _report {
	local raw="$1" since="$2"
	shift 2
	# Each pattern is awk source, tested with the login as \$0.
	local pats=""
	local p
	for p in "$@"; do
		pats+="${pats:+ || }($p)"
	done
	pats="${pats:-1}"

	if [[ ! -r /var/log/gateway-sessions.log ]]; then
		echo "$(hostname): no /var/log/gateway-sessions.log;" \
			"run install-session-log.sh there" 1>&2
		return 1
	fi

	{ pgrep -x sshd | sed 's/^/live\t/'
	  # dateext names the copies -YYYYMM.gz, so name order is time order.
	  for f in /var/log/gateway-sessions.log-*.gz; do
		[[ -r "$f" ]] && zcat "$f"
	  done
	  cat /var/log/gateway-sessions.log
	} | TZ=UTC LC_ALL=C gawk -F'\t' -v OFS='\t' \
		-v raw="$raw" -v since="$since" '
	function secs(t) {
		gsub(/[-T:Z]/, " ", t)
		return mktime(t)
	}
	function len(s,   d, h, m) {
		d = int(s / 86400); s -= d * 86400
		h = int(s / 3600); s -= h * 3600
		m = int(s / 60); s -= m * 60
		if (d) return sprintf("%dd%02dh%02dm", d, h, m)
		if (h) return sprintf("%dh%02dm", h, m)
		if (m) return sprintf("%dm%02ds", m, s)
		return sprintf("%ds", s)
	}
	$1 == "live" { live[$2] = 1; next }
	NF < 6 { next }
	# The journal history and the hook can both record one event.
	seen[$2, $3, $6, substr($1, 1, 13)]++ { next }
	{
		line = $0
		$0 = $3
		ok = ('"$pats"')
		$0 = line
	}
	!ok { next }
	raw { if ($1 >= since) print; next }
	$2 == "open" {
		k = $3 SUBSEP $6
		if (k in open)
			emit(k, "lost")
		open[k] = $0
		order[++n] = k
		next
	}
	$2 == "close" {
		k = $3 SUBSEP $6
		if (k in open)
			emit(k, $1)
		else if ($1 >= since)
			print $3, $4, "?", $1, "?", $5
		next
	}
	function emit(k, closed,   f, s) {
		split(open[k], f, "\t")
		delete open[k]
		if (closed ~ /^[0-9]/) {
			if (closed < since)
				return
			s = len(secs(closed) - secs(f[1]))
		} else {
			s = "-"
		}
		print f[3], f[4], f[1], closed, s, f[5]
	}
	END {
		if (raw)
			exit
		now = systime()
		for (i = 1; i <= n; i++) {
			k = order[i]
			if (!(k in open))
				continue
			split(open[k], f, "\t")
			if (f[6] in live)
			{
				print f[3], f[4], f[1], "up", len(now - secs(f[1])), f[5]
				delete open[k]
			} else
				emit(k, "lost")
		}
	}' | if [[ "$raw" -ne 0 ]]; then cat; else sort -t$'\t' -k3,3 -s; fi
}

typeset -i OPTRAW=0
typeset -i OPTLOCAL=0
JUMPHOST=
SINCE=

while getopts hlrH:S: opt; do
	case "$opt" in
	h)	_help; exit 0 ;;
	l)	OPTLOCAL=1 ;;
	r)	OPTRAW=1 ;;
	H)	JUMPHOST="$OPTARG" ;;
	S)	SINCE="$OPTARG" ;;
	*)	echo "Usage: $USAGE" 1>&2; exit 1 ;;
	esac
done
shift $((OPTIND - 1))

if [[ $OPTLOCAL -eq 0 && -z "$JUMPHOST" ]]; then
	if [[ -r "$LOGDIR/$LOGNAME" ]]; then
		OPTLOCAL=1
	else
		JUMPHOST="$DEFAULTJUMPHOST"
	fi
fi

if [[ $OPTLOCAL -ne 0 ]]; then
	_report "$OPTRAW" "$SINCE" "$@"
else
	# Send _report to the jumphost and run it there with the same
	# arguments.
	# shellcheck disable=2029 # the arguments expand here, on purpose.
	ssh -o BatchMode=yes "$JUMPHOST" \
		"$(declare -f _report); _report ${OPTRAW@Q} ${SINCE@Q} ${*@Q}"
fi
