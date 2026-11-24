#!/bin/bash

#
# Name: seed-gateway-state.sh
#
# Function:
#	Write a record for each gateway in an org inventory to
#	~<login>/gateway_state.json on the jumphost, if it has none.
#

PNAME="$(basename "$0")"
PPATH="$(cd "$(dirname "$0")" && pwd)"

USAGE="$PNAME [-fhn] -o org-dir [-C ttn-multitech-cm-dir] [-H host] [pattern ...]"

function _help {
	more 1>&2 <<.

Name:	$PNAME

Function:
	Seed the jumphost with a record for each gateway in an org
	inventory, so that gateway-info.sh can describe gateways that
	are offline.

Usage:
	$USAGE

Operation:
	Runs ansible/seed.yml in ttn-multitech-cm's container (bin/run)
	against the org inventory. The play never connects to a gateway:
	it reads each gateway's variables from the inventory and writes
	~<login>/gateway_state.json on the jumphost, with
	"source": "inventory". A record that exists, whether seeded or
	pushed by the gateway, is left alone unless -f is given.

	It also sets each gateway's home directory on the jumphost to
	group wheel, mode 2750, so that people in wheel can read the
	records.

	Patterns are regular expressions matched against inventory
	names, as in kick-all-gateways.sh; with none, all gateways in
	the inventory that use the jumphost are seeded.

	Needs what an apply needs (Docker, a logged-in ttn-lw-cli), and
	sudo on the jumphost.

Options:
	-o dir	the org repo (for example ../org-ttn-nyc-gateways).
	-C dir	the ttn-multitech-cm checkout to run bin/run from
		(default $PPATH/../ttn-multitech-cm).
	-H host	the jumphost (default jumphost.ttni.tech).
	-f	replace records that exist.
	-n	check mode: show what would change, change nothing.
	-h	print this help.
.
}

CMDIR="$PPATH/../ttn-multitech-cm"
ORGDIR=
JUMPHOST=jumphost.ttni.tech
typeset -i OPTFORCE=0
typeset -i OPTCHECK=0

while getopts fhnC:H:o: opt; do
	case "$opt" in
	f)	OPTFORCE=1 ;;
	h)	_help; exit 0 ;;
	n)	OPTCHECK=1 ;;
	C)	CMDIR="$OPTARG" ;;
	H)	JUMPHOST="$OPTARG" ;;
	o)	ORGDIR="$OPTARG" ;;
	*)	echo "Usage: $USAGE" 1>&2; exit 1 ;;
	esac
done
shift $((OPTIND - 1))

if [[ -z "$ORGDIR" ]]; then
	echo "$PNAME: -o org-dir is required" 1>&2
	echo "Usage: $USAGE" 1>&2
	exit 1
fi
ORGDIR="$(realpath "$ORGDIR")" || exit 1
CMDIR="$(realpath "$CMDIR")" || exit 1

if [[ ! -x "$CMDIR/bin/run" ]]; then
	echo "$PNAME: no bin/run in $CMDIR; use -C" 1>&2
	exit 1
fi

# bin/run mounts \$PWD, \$HOME and TTN_ORG in the container, so the play
# must be under one of them.
case "$PPATH/" in
"$HOME"/*|"$CMDIR"/*)	;;
*)	echo "$PNAME: $PPATH is outside \$HOME; bin/run can't see it" 1>&2
	exit 1 ;;
esac

# The Makefile's rule: hosts if present, else inventory.
if [[ -e "$ORGDIR/hosts" ]]; then
	INVENTORY="$ORGDIR/hosts"
else
	INVENTORY="$ORGDIR/inventory"
fi

# ttn-multitech-cm's container has no git, so find the org repo's
# version here.
CONFIGVERSION="$(git -C "$ORGDIR" describe --tags --always --dirty 2>/dev/null)"

EXTRAVARS="$(python3 -c '
import json, sys
print(json.dumps({
	"seed_jumphost": sys.argv[1],
	"seed_force": sys.argv[2] == "1",
	"seed_config_version": sys.argv[3] or "unknown",
	"seed_patterns": sys.argv[4:],
}))' "$JUMPHOST" "$OPTFORCE" "$CONFIGVERSION" "$@")" || exit 1

CHECKARGS=()
if [[ $OPTCHECK -ne 0 ]]; then
	CHECKARGS=(--check --diff)
fi

cd "$CMDIR" || exit 1
TTN_ORG="$ORGDIR" exec bin/run ansible-playbook -i "$INVENTORY" \
	"${CHECKARGS[@]}" -e "$EXTRAVARS" "$PPATH/ansible/seed.yml"
