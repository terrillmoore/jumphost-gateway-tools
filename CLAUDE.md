# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bash scripts that run on the jumphost for gateways set up by the
[conduit-mfg](https://github.com/terrillmoore/conduit-mfg) procedures (Multitech
Conduits running mLinux, with either the TTN packet forwarder or Basic Station). Each gateway holds a
reverse ssh tunnel to the jumphost, listening on `::1:20xxx`. Each gateway also
has a jumphost login whose UID equals its tunnel port.

There is no build and no test suite. Check scripts with `shellcheck`; the code
already carries `shellcheck disable` comments where a warning is intended.

## Scripts

- `live-gateways.sh` lists connected gateways as `login<TAB>port`. It reads
  listening ports from `netstat -ln`, then joins them against `/etc/passwd`
  by UID. It only works on the jumphost.
- `kick-all-gateways.sh [options] [pattern ...]` calls `live-gateways.sh`,
  filters logins through the awk patterns given as arguments (none means all
  gateways), and runs `_kickgateway` on each one. `-h` prints the option list.

## How `kick-all-gateways.sh` works

`_kickgateway` does all its work in one `ssh -p <port> root@localhost` call.
The remote command is a single-quoted shell script; the local option values
are spliced in by closing and reopening the quotes (`'"$OPTQUERY"'`), and
literal single quotes inside the remote script are written `'\''`. When you
edit the remote part, keep track of which shell expands each `$`: most of the
script expands on the gateway, not on the jumphost.

The remote script first works out the transport, `packet_forwarder` or
`basic_station`. It reads `/var/config/lora/gateway_info.json` (written by
ttn-multitech-cm) through the `gwinfo` shell function. That function uses sed
and expects one key per line. If the file has no transport, the script looks
for a K30 kill script in `/etc/rc6.d`. The same file can give the pid file, log
file, init script and description. A missing key falls back to the default for
the transport:

| Transport          | Pid file                     | Log file                     | Init script                       |
|--------------------|------------------------------|------------------------------|-----------------------------------|
| `packet_forwarder` | `/var/run/lora-pkt-fwd.pid`  | `/var/log/lora-pkt-fwd.log`  | `/etc/init.d/ttn-pkt-forwarder`   |
| `basic_station`    | `/var/run/lora/station.pid`  | `/var/log/basic-station.log` | `/etc/init.d/lora-basic-station`  |

The script then reports status:

- Pid file missing means `stopped`; a dead PID means `crashed`.
- A log file older than 10 minutes means `hung`.
- On the packet forwarder only, a last log line of
  `ERROR: [main] failed to start the concentrator` turns `crashed` into `concentrator`.
- `/var/log` usage over 75% means `full`.
- With an unknown transport, the script skips these checks and cannot restart
  the forwarder.

`hung`, `full`, `concentrator`, `-R` and `-B` lead to `reboot`; other faults
run the init script's `restart`. `-Q` reports without acting.

Output is one line per gateway, fields joined by the `-f` separator (default
`": "`): login, port, `-s` stats, EUI, mLinux version, `-L` description, status.

Option parsing uses `getopts` with an undocumented `-n` that negates the next
boolean option (for example `-nQ`). Boolean options are `typeset -i` variables
named `OPT*`. A new option needs changes in the `getopts` string, the `case`,
`USAGE`, the `_help` text, and, if the gateway needs it, the remote variable list.

## Testing changes

Running the script against live gateways can restart forwarders or reboot
gateways. Use `-Q`, and a pattern that selects one gateway, when trying a change:

```bash
./kick-all-gateways.sh -Q ttn-ithaca-00-08-00-4a-37-69
```

License: MIT (see `LICENSE`).
