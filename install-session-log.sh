#!/bin/bash

#
# Name: install-session-log.sh
#
# Function:
#	Set up the gateway session log on the jumphost. Run as root on
#	the jumphost, from this directory:
#
#	sudo ./install-session-log.sh
#
#	It is safe to run again; each step checks whether it is done.
#
# Steps:
#	1. Copy gw-session-log to /usr/local/sbin.
#	2. Create /var/log/gateway-sessions.log (mode 0644).
#	3. Write /etc/logrotate.d/gateway-sessions: monthly, keep 36.
#	4. Add the pam_exec line to /etc/pam.d/sshd, after saving a copy
#	   as /etc/pam.d/sshd.orig-<time>.
#	5. If gateway-sessions.log has no lines from before step 4, read
#	   the sshd lines in the journal up to step 4 and put the sessions
#	   they record at the front of the log.
#

set -e

PNAME="$(basename "$0")"
PPATH="$(cd "$(dirname "$0")" && pwd)"

HOOK=/usr/local/sbin/gw-session-log
LOG=/var/log/gateway-sessions.log
LOGROTATE=/etc/logrotate.d/gateway-sessions
PAMFILE=/etc/pam.d/sshd
PAMLINE="session    optional     pam_exec.so quiet $HOOK"

if [ "$(id -u)" -ne 0 ]; then
	echo "$PNAME: must run as root" 1>&2
	exit 1
fi

install -m 0755 -o root -g root "$PPATH/gw-session-log" "$HOOK"
echo "$PNAME: installed $HOOK"

touch "$LOG"
chmod 0644 "$LOG"

cat > "$LOGROTATE" <<.
$LOG {
	monthly
	rotate 36
	compress
	dateext
	dateformat -%Y%m
	missingok
	notifempty
	create 0644 root root
}
.
echo "$PNAME: wrote $LOGROTATE"

if grep -q -F "$HOOK" "$PAMFILE"; then
	echo "$PNAME: $PAMFILE already calls $HOOK"
	PAMTIME=
else
	BACKUP="$PAMFILE.orig-$(date -u +%Y%m%d%H%M%S)"
	cp -p "$PAMFILE" "$BACKUP"
	echo "$PAMLINE" >> "$PAMFILE"
	PAMTIME="$(date -u '+%Y-%m-%d %H:%M:%S')"
	echo "$PNAME: added the hook to $PAMFILE (copy in $BACKUP)"
fi

# Journal history goes in only on the run that adds the hook, so it
# ends where the hook's lines begin.
if [ -z "$PAMTIME" ]; then
	exit 0
fi

TEMP="$(mktemp)"
trap 'rm -f "$TEMP" "$TEMP.new"' EXIT

journalctl --utc -o short-iso --no-pager -q -t sshd --until "$PAMTIME" \
	-g 'Accepted publickey for |session (opened|closed) for user ' |
LC_ALL=C awk -v OFS='\t' '
	# /etc/passwd first: map login to UID.
	FNR == NR {
		split($0, f, ":")
		uid[f[1]] = f[3]
		next
	}
	{
		t = $1
		sub(/\+00:?00$/, "Z", t)
		if (! match($3, /\[[0-9]+\]/))
			next
		pid = substr($3, RSTART + 1, RLENGTH - 2)
	}
	/ Accepted publickey for / {
		for (i = 1; i < NF; i++)
			if ($i == "from")
				rhost[pid] = $(i + 1)
		next
	}
	/ session (opened|closed) for user / {
		ev = ($0 ~ / session opened /) ? "open" : "close"
		match($0, /for user [^( ]+/)
		u = substr($0, RSTART + 9, RLENGTH - 9)
		# Same test as gw-session-log.
		if (!(u in uid) || uid[u] < 20000 || uid[u] > 29999)
			next
		if (u !~ /-([0-9a-f][0-9a-f]-){5}[0-9a-f][0-9a-f]$/ &&
		    u !~ /-[0-9a-f]{12}$/)
			next
		r = (pid in rhost) ? rhost[pid] : "-"
		print t, ev, u, uid[u], r, pid
		if (ev == "close")
			delete rhost[pid]
	}
' /etc/passwd - > "$TEMP"

# Put the journal lines first, rewriting the log in place (same inode)
# under the hook's lock, so no line the hook writes meanwhile is lost.
{
	flock 9
	cat "$TEMP" "$LOG" > "$TEMP.new"
	cat "$TEMP.new" > "$LOG"
} 9>>"$LOG"

echo "$PNAME: added $(wc -l < "$TEMP") lines from the journal"
