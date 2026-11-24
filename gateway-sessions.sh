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

USAGE="$PNAME [-hlrs] [-H host] [-S since] [pattern ...]"

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
	The arguments after the options are regular expressions, matched
	against gateway login names as in kick-all-gateways.sh (18-c6
	selects ttn-nyc-00-08-00-4a-18-c6); with none, all gateways are
	shown.

	Output is one line per session, tab-separated: login, port,
	opened, closed, length, remote address. Times are UTC. "up" in
	the closed column means the session is still open; "lost" means
	the log has no close for it and its sshd is gone.

	With -s, output is one line per gateway, tab-separated: login,
	port, sessions, average length of the closed sessions, and now:
	"up" and how long (from the log; "?" if the session opened before
	the log starts); "no-tunnel" and how long, if the session is open
	but the tunnel port isn't listening; or "down" and when the last
	session closed. A gateway is up if its tunnel port is listening,
	so -s also shows gateways that have been connected since before
	the log starts.

Options:
	-H host	read the log on this jumphost (default $DEFAULTJUMPHOST,
		or this machine if it has the log).
	-l	read the log on this machine.
	-r	print the log lines themselves, not sessions.
	-s	print a summary for each gateway, not sessions.
	-S since
		start at this time: any prefix of 2026-11-24T16:49:10Z,
		for example 2026-11 or 2026-11-24T16.
	-h	print this help.
.
}

# Runs on the machine that has the log. Arguments: mode (sessions,
# raw or summary), since, then the patterns.
function _report {
	local mode="$1" since="$2"
	shift 2
	# Each pattern is a regular expression matched against the login,
	# as in kick-all-gateways.sh: 18-c6 means \$0 ~ /18-c6/.
	local pats=""
	local p
	for p in "$@"; do
		p="${p//\//\\/}"
		pats+="${pats:+ || }(\$0 ~ /$p/)"
	done
	pats="${pats:-1}"

	if [[ ! -r /var/log/gateway-sessions.log ]]; then
		echo "$(hostname): no /var/log/gateway-sessions.log;" \
			"run install-session-log.sh there" 1>&2
		return 1
	fi

	# Input to gawk: sshd pids, listening tunnel ports and gateway
	# logins, each line tagged, then the log lines oldest first.
	{ pgrep -x sshd | sed 's/^/live\t/'
	  netstat -ln 2>/dev/null |
		gawk '$4 ~ /^::1:2[0-9][0-9][0-9][0-9]$/ {
			print "port\t" substr($4, 5) }'
	  gawk -F: '$3 >= 20000 && $3 <= 29999 { print "pw\t" $1 "\t" $3 }' \
		/etc/passwd
	  # dateext names the copies -YYYYMM.gz, so name order is time order.
	  for f in /var/log/gateway-sessions.log-*.gz; do
		[[ -r "$f" ]] && zcat "$f"
	  done
	  cat /var/log/gateway-sessions.log
	} | TZ=UTC LC_ALL=C gawk -F'\t' -v OFS='\t' \
		-v mode="$mode" -v since="$since" '
	function want(login) {
		$0 = login
		return ('"$pats"')
	}
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
	$1 == "port" { port[$2] = 1; next }
	$1 == "pw" { pwuid[$2] = $3; next }
	NF < 6 { next }
	# The journal history and the hook can both record one event.
	seen[$2, $3, $6, substr($1, 1, 13)]++ { next }
	{
		line = $0
		ok = want($3)
		$0 = line
	}
	!ok { next }
	mode == "raw" { if ($1 >= since) print; next }
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
			out($3, $4, "?", $1, -1, $5)
		next
	}
	# One session: print it, or add it to the summary. dur is the
	# length in seconds, or -1 if unknown (no open, or no close).
	function out(login, uid, opened, closed, dur, rhost) {
		if (mode != "summary") {
			print login, uid, opened, closed,
				(dur >= 0 ? len(dur) : opened == "?" ? "?" : "-"), rhost
			return
		}
		gwuid[login] = uid
		nsess[login]++
		if (closed ~ /^[0-9]/) {
			lastclose[login] = closed
			if (dur >= 0) {
				nlen[login]++
				tlen[login] += dur
			}
		} else if (closed == "up") {
			uplen[login] = dur
		}
	}
	function emit(k, closed,   f, s) {
		split(open[k], f, "\t")
		delete open[k]
		if (closed ~ /^[0-9]/) {
			if (closed < since)
				return
			s = secs(closed) - secs(f[1])
		} else {
			s = -1
		}
		out(f[3], f[4], f[1], closed, s, f[5])
	}
	END {
		if (mode == "raw")
			exit
		now = systime()
		for (i = 1; i <= n; i++) {
			k = order[i]
			if (!(k in open))
				continue
			split(open[k], f, "\t")
			if (f[6] in live)
			{
				out(f[3], f[4], f[1], "up", now - secs(f[1]), f[5])
				delete open[k]
			} else
				emit(k, "lost")
		}
		if (mode != "summary")
			exit
		# Gateways with a listening tunnel but nothing in the log.
		for (l in pwuid)
			if ((pwuid[l] in port) && !(l in gwuid) && want(l))
				gwuid[l] = pwuid[l]
		for (l in gwuid) {
			if (pwuid[l] in port)
				st = "up " ((l in uplen) ? len(uplen[l]) : "?")
			else if (l in uplen)
				st = "no-tunnel " len(uplen[l])
			else if (l in lastclose)
				st = "down since " lastclose[l]
			else
				st = "down"
			print l, gwuid[l], nsess[l] + 0,
				nlen[l] ? len(int(tlen[l] / nlen[l])) : "-", st
		}
	}' | case "$mode" in
	raw)		cat ;;
	summary)	sort ;;
	*)		sort -t$'\t' -k3,3 -s ;;
	esac
}

MODE=sessions
typeset -i OPTLOCAL=0
JUMPHOST=
SINCE=

while getopts hlrsH:S: opt; do
	case "$opt" in
	h)	_help; exit 0 ;;
	l)	OPTLOCAL=1 ;;
	r)	MODE=raw ;;
	s)	MODE=summary ;;
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
	_report "$MODE" "$SINCE" "$@"
else
	# Send _report to the jumphost and run it there with the same
	# arguments.
	# shellcheck disable=2029 # the arguments expand here, on purpose.
	ssh -o BatchMode=yes "$JUMPHOST" \
		"$(declare -f _report); _report ${MODE@Q} ${SINCE@Q} ${*@Q}"
fi
