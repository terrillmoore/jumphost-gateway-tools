#!/bin/bash

#
# Name: gateway-info.sh
#
# Function:
#	Describe gateways, online or not, from the records in their home
#	directories on the jumphost.
#

PNAME="$(basename "$0")"

DEFAULTJUMPHOST=jumphost.ttni.tech

USAGE="$PNAME [-adhlu] [-f sep] [-H host] [-o json] [pattern ...]"

function _help {
	more 1>&2 <<.

Name:	$PNAME

Function:
	Describe each gateway known to the jumphost, whether or not it is
	connected now.

Usage:
	$USAGE

Operation:
	Reads ~<login>/gateway_state.json for each gateway login on the
	jumphost. seed-gateway-state.sh writes these from the inventory;
	later, gateways will replace them with records of their own.

	The arguments after the options are regular expressions, matched
	against gateway login names as in kick-all-gateways.sh; with none,
	all gateways are shown.

	Output is one line per gateway: login, port, now, source,
	description, mLinux version, forwarder. On a terminal it is a
	table with a header; otherwise, or with -f, the fields are
	separated by tabs (or the -f separator). "now" is "up" if
	the gateway's tunnel port is listening, otherwise "down" and the
	time its last session closed (from gateway-sessions.log), or
	"down" alone. "source" is "inventory" or "gateway", or "-" if
	the gateway has no record (shown only with -a, or when it is up).

Options:
	-a	also show gateway logins with no record that are down
		(usually retired gateways).
	-d	show only gateways that are down.
	-f sep	print separated lines, not a table, with this separator
		between fields (default a tab).
	-H host	read the records on this jumphost (default
		$DEFAULTJUMPHOST, or this machine if it has gateway tunnels).
	-l	read the records on this machine.
	-o json	print one JSON object per gateway per line: the record,
		with "now" and "last_close" added.
	-u	show only gateways that are up.
	-h	print this help.
.
}

# Runs on the jumphost. Arguments: all (0/1), format (text/json), state
# to show (up, down, or empty for both), separator (empty for a table),
# then the patterns.
function _report {
	python3 - "$@" <<'PY'
import glob, gzip, json, pwd, re, subprocess, sys

show_all = sys.argv[1] == "1"
fmt, only, sep = sys.argv[2:5]
pats = [re.compile(p) for p in sys.argv[5:]]
rows = []

# Same test as gw-session-log: UID 20000-29999 and a name that ends in
# the gateway's MAC address.
login_re = re.compile(r"-([0-9a-f]{2}-){5}[0-9a-f]{2}$|-[0-9a-f]{12}$")

ports = set()
out = subprocess.run(["netstat", "-ln"], capture_output=True, text=True).stdout
for line in out.splitlines():
	f = line.split()
	if len(f) > 3:
		m = re.fullmatch(r"::1:(2\d{4})", f[3])
		if m:
			ports.add(int(m.group(1)))

last_close = {}
logs = sorted(glob.glob("/var/log/gateway-sessions.log-*.gz"))
for path in logs + ["/var/log/gateway-sessions.log"]:
	try:
		opener = gzip.open if path.endswith(".gz") else open
		with opener(path, "rt") as fh:
			for line in fh:
				f = line.rstrip("\n").split("\t")
				if len(f) >= 3 and f[1] == "close":
					last_close[f[2]] = f[0]
	except OSError:
		pass

for pw in sorted(pwd.getpwall(), key=lambda p: p.pw_name):
	login, uid = pw.pw_name, pw.pw_uid
	if not 20000 <= uid <= 29999 or not login_re.search(login):
		continue
	if pats and not any(p.search(login) for p in pats):
		continue
	try:
		with open(pw.pw_dir + "/gateway_state.json") as fh:
			rec = json.load(fh)
	except (OSError, ValueError):
		rec = None
	up = uid in ports
	if only and only != ("up" if up else "down"):
		continue
	if rec is None and not up and not show_all:
		continue
	rec = dict(rec or {})
	rec.setdefault("login", login)
	rec.setdefault("port", uid)
	rec["now"] = "up" if up else "down"
	rec["last_close"] = last_close.get(login)
	if fmt == "json":
		print(json.dumps(rec, sort_keys=True))
		continue
	now = rec["now"]
	if not up and rec["last_close"]:
		now += " since " + rec["last_close"]
	row = [str(x if x is not None else "-") for x in (
		login, uid, now, rec.get("source"), rec.get("description"),
		rec.get("mlinux_version"), rec.get("forwarder_variant"))]
	if sep:
		print(sep.join(row))
	else:
		rows.append(row)

if rows:
	rows.insert(0, ["ID", "PORT", "NOW", "SOURCE", "DESCRIPTION",
		"MLINUX", "FORWARDER"])
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
PY
}

typeset -i OPTALL=0
typeset -i OPTLOCAL=0
JUMPHOST=
FORMAT=text
ONLY=
OPTSEP=

while getopts adf:hluH:o: opt; do
	case "$opt" in
	a)	OPTALL=1 ;;
	d)	ONLY=down ;;
	f)	OPTSEP="$OPTARG" ;;
	h)	_help; exit 0 ;;
	l)	OPTLOCAL=1 ;;
	u)	ONLY=up ;;
	H)	JUMPHOST="$OPTARG" ;;
	o)	case "$OPTARG" in
		json)	FORMAT=json ;;
		*)	echo "$PNAME: -o takes json" 1>&2; exit 1 ;;
		esac ;;
	*)	echo "Usage: $USAGE" 1>&2; exit 1 ;;
	esac
done
shift $((OPTIND - 1))

# A table only on a terminal; the jumphost can't tell, since ssh runs
# _report without one.
if [[ -z "$OPTSEP" && ! -t 1 ]]; then
	OPTSEP=$'\t'
fi

# As in kick-all-gateways.sh: this machine is the jumphost if gateway
# tunnels end here.
if [[ $OPTLOCAL -eq 0 && -z "$JUMPHOST" ]]; then
	if netstat -ln 2>/dev/null | grep -q '::1:20[0-9][0-9][0-9] '; then
		OPTLOCAL=1
	else
		JUMPHOST="$DEFAULTJUMPHOST"
	fi
fi

if [[ $OPTLOCAL -ne 0 ]]; then
	_report "$OPTALL" "$FORMAT" "$ONLY" "$OPTSEP" "$@"
else
	# shellcheck disable=2029 # the arguments expand here, on purpose.
	ssh -o BatchMode=yes "$JUMPHOST" \
		"$(declare -f _report); _report ${OPTALL@Q} ${FORMAT@Q} ${ONLY@Q} ${OPTSEP@Q} ${*@Q}"
fi
