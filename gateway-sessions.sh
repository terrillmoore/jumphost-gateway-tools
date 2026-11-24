#!/bin/bash

#
# Name: gateway-sessions.sh
#
# Function:
#	Show the connect history of gateways, from the session log that
#	gw-session-log writes on the jumphost, with what the jumphost's
#	gateway records say about each gateway.
#

PNAME="$(basename "$0")"

DEFAULTJUMPHOST=jumphost.ttni.tech
LOGDIR=/var/log
LOGNAME=gateway-sessions.log

USAGE="$PNAME [-hLlrs] [-f sep] [-H host] [-o format] [-S since] [pattern ...]"

function _help {
	more 1>&2 <<.

Name:	$PNAME

Function:
	Show when each gateway's ssh session to the jumphost opened and
	closed.

Usage:
	$USAGE

Operation:
	Reads $LOGDIR/$LOGNAME and its rotated copies on the jumphost,
	and each gateway's record, ~<login>/gateway_state.json (written by
	seed-gateway-state.sh). The arguments after the options are
	regular expressions, matched against gateway login names as in
	kick-all-gateways.sh (18-c6 selects ttn-nyc-00-08-00-4a-18-c6);
	with none, all gateways are shown.

	Output is one line per session: login, port, opened, closed, length, remote address, then from the
	record: mLinux version, forwarder, link (ethernet or cellular), and
	with -L the description. Times are UTC. "up" in the closed column
	means the session is still open; "lost" means the log has no close
	for it and its sshd is gone; "?" means the session opened before
	the log starts.

	With -s, output is one line per gateway: login, port, sessions,
	average length of the closed sessions, mLinux version, forwarder,
	link, with -L the description, and last the state now: "up" and
	how long (from the log; "?" if the session opened before the log
	starts); "no-tunnel" and how long, if the session is open but the
	tunnel port isn't listening; or "down" and when the last session
	closed. A gateway is up if its tunnel port is listening, so -s
	also shows gateways that have been connected since before the log
	starts.

	On a terminal the output is a table with a header; otherwise, or
	with -f, the fields are joined by the -f separator. A field with
	no value prints as "-".

Options:
	-f sep	print separated lines, not a table, with this separator
		between fields (default ': ' when output is not a
		terminal).
	-H host	read the log on this jumphost (default $DEFAULTJUMPHOST,
		or this machine if it has the log).
	-l	read the log on this machine.
	-L	add each gateway's description.
	-o format
		text (the default), or json for one JSON object per line,
		with every field whatever -L says, and null for missing
		values.
	-r	print the log lines themselves, not sessions.
	-s	print a summary for each gateway, not sessions.
	-S since
		start at this time: any prefix of 2026-11-24T16:49:10Z,
		for example 2026-11 or 2026-11-24T16. Shows sessions
		that closed at or after it, lost sessions that opened at
		or after it, and sessions still open.
	-h	print this help.
.
}

# Runs on the machine that has the log. Arguments: mode (sessions, raw
# or summary), since, separator (empty for a table), description (0/1),
# format (text or json), then the patterns.
function _report {
	if [[ ! -r /var/log/gateway-sessions.log ]]; then
		echo "$(hostname): no /var/log/gateway-sessions.log;" \
			"run install-session-log.sh there" 1>&2
		return 1
	fi
	python3 - "$@" <<'PY'
import calendar, glob, gzip, json, pwd, re, subprocess, sys, time

mode, since, sep, show_desc, fmt = sys.argv[1:6]
show_desc = show_desc == "1"
pats = [re.compile(p) for p in sys.argv[6:]]

def want(login):
	return not pats or any(p.search(login) for p in pats)

def secs(t):
	return calendar.timegm(time.strptime(t, "%Y-%m-%dT%H:%M:%SZ"))

def length(s):
	s = int(s)
	d, s = divmod(s, 86400)
	h, s = divmod(s, 3600)
	m, s = divmod(s, 60)
	if d:
		return "%dd%02dh%02dm" % (d, h, m)
	if h:
		return "%dh%02dm" % (h, m)
	if m:
		return "%dm%02ds" % (m, s)
	return "%ds" % s

def run(argv):
	return subprocess.run(argv, capture_output=True, text=True).stdout

# sshd pids now running, and gateway tunnel ports now listening.
live = set(run(["pgrep", "-x", "sshd"]).split())
ports = set()
for line in run(["netstat", "-ln"]).splitlines():
	f = line.split()
	if len(f) > 3:
		m = re.fullmatch(r"::1:(2\d{4})", f[3])
		if m:
			ports.add(int(m.group(1)))

# The gateway's record, as far as this report uses it.
records = {}
def info(login):
	if login not in records:
		try:
			home = pwd.getpwnam(login).pw_dir
			with open(home + "/gateway_state.json") as fh:
				rec = json.load(fh)
		except (KeyError, OSError, ValueError):
			rec = {}
		cell = rec.get("use_cellular")
		records[login] = {
			"mlinux_version": rec.get("mlinux_version"),
			"forwarder_variant": rec.get("forwarder_variant"),
			"link": None if cell is None else
				"cellular" if cell else "ethernet",
			"description": rec.get("description"),
		}
	return records[login]

rows = []
def emit_line(fields, tail):
	"""Print fields, then the record's fields, then tail; or keep them
	for the table."""
	i = info(fields[0])
	out = list(fields) + [i["mlinux_version"], i["forwarder_variant"],
		i["link"]]
	if show_desc:
		out.append(i["description"])
	out += tail
	out = ["-" if x is None else str(x) for x in out]
	if sep:
		print(sep.join(out))
	else:
		rows.append(out)

def print_table(head, tail):
	"""Print the kept rows as a table under a header."""
	if not rows:
		return
	head = head + ["MLINUX", "FORWARDER", "LINK"]
	if show_desc:
		head.append("DESCRIPTION")
	rows.insert(0, head + tail)
	# Box-drawing borders; UTF-8 whatever the locale under ssh.
	sys.stdout.reconfigure(encoding="utf-8")
	w = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
	def rule(left, mid, right):
		print(left + mid.join("─" * (n + 2) for n in w) + right)
	rule("┌", "┬", "┐")
	for i, r in enumerate(rows):
		print("│" + "│".join(
			" " + c.ljust(n) + " " for c, n in zip(r, w)) + "│")
		if i == 0:
			rule("├", "┼", "┤")
	rule("└", "┴", "┘")

def emit_json(obj):
	obj.update(info(obj["login"]))
	print(json.dumps(obj))

# Read the log, oldest first. The journal history and the hook can both
# record one event, so drop repeats of (event, login, pid, hour).
lines = []
for path in sorted(glob.glob("/var/log/gateway-sessions.log-*.gz")) + \
		["/var/log/gateway-sessions.log"]:
	try:
		opener = gzip.open if path.endswith(".gz") else open
		with opener(path, "rt") as fh:
			lines += fh.read().splitlines()
	except OSError:
		pass

seen = set()
events = []
for line in lines:
	f = line.split("\t")
	if len(f) < 6:
		continue
	key = (f[1], f[2], f[5], f[0][:13])
	if key in seen:
		continue
	seen.add(key)
	if not want(f[2]):
		continue
	if mode == "raw":
		if f[0] >= since:
			print(line)
		continue
	events.append(f)
if mode == "raw":
	sys.exit(0)

# Pair each open with the close of the same login and pid.
sessions = []	# (login, port, opened, closed, seconds or None, address)
opened = {}
order = []

def finish(k, closed):
	f = opened.pop(k)
	if closed[0].isdigit():
		if closed < since:
			return
		dur = secs(closed) - secs(f[0])
	else:
		# A lost session has no close time; go by when it opened.
		if f[0] < since:
			return
		dur = None
	sessions.append((f[2], int(f[3]), f[0], closed, dur, f[4]))

for f in events:
	k = (f[2], f[5])
	if f[1] == "open":
		if k in opened:
			finish(k, "lost")
		opened[k] = f
		order.append(k)
	elif f[1] == "close":
		if k in opened:
			finish(k, f[0])
		elif f[0] >= since:
			sessions.append((f[2], int(f[3]), "?", f[0], None, f[4]))

now = time.time()
for k in order:
	if k not in opened:
		continue
	f = opened[k]
	if f[5] in live:
		opened.pop(k)
		sessions.append((f[2], int(f[3]), f[0], "up",
			int(now - secs(f[0])), f[4]))
	else:
		finish(k, "lost")

if mode == "sessions":
	# By time opened; sessions with no open time first.
	sessions.sort(key=lambda s: "" if s[2] == "?" else s[2])
	for login, port, op, cl, dur, addr in sessions:
		if fmt == "json":
			emit_json({"login": login, "port": port,
				"opened": None if op == "?" else op,
				"closed": cl, "seconds": dur, "address": addr})
		else:
			emit_line((login, port, op, cl,
				length(dur) if dur is not None else
				"?" if op == "?" else None, addr), [])
	print_table(["LOGIN", "PORT", "OPENED", "CLOSED", "LENGTH",
		"ADDRESS"], [])
	sys.exit(0)

# Summary: one line per gateway.
gw = {}
for login, port, op, cl, dur, addr in sessions:
	g = gw.setdefault(login, {"port": port, "n": 0, "total": 0,
		"closed": 0, "last_close": None, "up": None})
	g["n"] += 1
	if cl[0].isdigit():
		g["last_close"] = max(g["last_close"] or "", cl)
		if dur is not None:
			g["closed"] += 1
			g["total"] += dur
	elif cl == "up":
		g["up"] = dur

# Gateways with a listening tunnel but nothing in the log.
for pw in pwd.getpwall():
	if 20000 <= pw.pw_uid <= 29999 and pw.pw_uid in ports and \
			pw.pw_name not in gw and want(pw.pw_name):
		gw[pw.pw_name] = {"port": pw.pw_uid, "n": 0, "total": 0,
			"closed": 0, "last_close": None, "up": None}

for login in sorted(gw):
	g = gw[login]
	avg = g["total"] // g["closed"] if g["closed"] else None
	if g["port"] in ports:
		state = "up"
		text = "up " + (length(g["up"]) if g["up"] is not None else "?")
	elif g["up"] is not None:
		state = "no-tunnel"
		text = "no-tunnel " + length(g["up"])
	elif g["last_close"]:
		state = "down"
		text = "down since " + g["last_close"]
	else:
		state = "down"
		text = "down"
	if fmt == "json":
		emit_json({"login": login, "port": g["port"],
			"sessions": g["n"], "average_seconds": avg,
			"now": state, "up_seconds": g["up"],
			"last_close": g["last_close"]})
	else:
		emit_line((login, g["port"], g["n"],
			length(avg) if avg is not None else None), [text])
print_table(["LOGIN", "PORT", "SESSIONS", "AVERAGE"], ["NOW"])
PY
}

MODE=sessions
OPTSEP=
FORMAT=text
typeset -i OPTDESC=0
typeset -i OPTLOCAL=0
JUMPHOST=
SINCE=

while getopts f:hlLrsH:o:S: opt; do
	case "$opt" in
	f)	OPTSEP="$OPTARG" ;;
	h)	_help; exit 0 ;;
	l)	OPTLOCAL=1 ;;
	L)	OPTDESC=1 ;;
	r)	MODE=raw ;;
	s)	MODE=summary ;;
	H)	JUMPHOST="$OPTARG" ;;
	o)	case "$OPTARG" in
		text|json)	FORMAT="$OPTARG" ;;
		*)	echo "$PNAME: -o takes text or json" 1>&2; exit 1 ;;
		esac ;;
	S)	SINCE="$OPTARG" ;;
	*)	echo "Usage: $USAGE" 1>&2; exit 1 ;;
	esac
done
shift $((OPTIND - 1))

# A table only on a terminal; the jumphost can't tell, since ssh runs
# _report without one.
if [[ -z "$OPTSEP" && ! -t 1 ]]; then
	OPTSEP=": "
fi

if [[ $OPTLOCAL -eq 0 && -z "$JUMPHOST" ]]; then
	if [[ -r "$LOGDIR/$LOGNAME" ]]; then
		OPTLOCAL=1
	else
		JUMPHOST="$DEFAULTJUMPHOST"
	fi
fi

if [[ $OPTLOCAL -ne 0 ]]; then
	_report "$MODE" "$SINCE" "$OPTSEP" "$OPTDESC" "$FORMAT" "$@"
else
	# Send _report to the jumphost and run it there with the same
	# arguments.
	# shellcheck disable=2029 # the arguments expand here, on purpose.
	ssh -o BatchMode=yes "$JUMPHOST" \
		"$(declare -f _report); _report ${MODE@Q} ${SINCE@Q} ${OPTSEP@Q} ${OPTDESC@Q} ${FORMAT@Q} ${*@Q}"
fi
