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
- `gateway-sessions.sh [options] [pattern ...]` prints the gateways'
  connect history from the session log (see below).
- `gateway-info.sh [options] [pattern ...]` describes gateways, connected or
  not, from the records in their jumphost home directories;
  `seed-gateway-state.sh -o org-dir` writes those records from an org
  inventory (see below).
- `kick-all-gateways.sh [options] [pattern ...]` calls `live-gateways.sh`,
  filters logins through the awk patterns given as arguments (none means all
  gateways), and runs `_kickgateway` on each one. `-h` prints the option list.

`kick-all-gateways.sh` runs `_kickgateway` as background jobs, at most `-j`
(default 32) at a time, using `wait -n -p` (bash 5.1 or later). Each job
writes to its own file in a `mktemp -d` directory. When a job ends, the script
prints its file and removes it, so lines come out in the order the gateways
answer, and one gateway's output never splits another's. Anything a job
prints, including ssh errors, goes into its file. If the running bash is older than 5.1
(macOS ships 3.2 as `/bin/bash`), the script runs itself again with a newer
bash from `PATH`, `/opt/homebrew/bin` or `/usr/local/bin`, or else exits with
an error. Keep that check, and everything before it, runnable by bash 3.2. On ^C the script sends
SIGTERM to its process group and removes the directory.

`-H {host}` names the jumphost, and `-l` says this machine is the jumphost.
With neither, the script checks `netstat -ln` for gateway tunnels on
`::1:20xxx`: if there are any, it acts as `-l`, otherwise as
`-H jumphost.ttni.tech` (`DEFAULTJUMPHOST`). The jumphost's hostname is an
EC2 internal name, so the script can't compare names.

With `-H`, `kick-all-gateways.sh` runs on another machine. It opens
one ssh master connection to the jumphost (`ControlPath` in the temp
directory), runs the local `live-gateways.sh` there with `bash -s`, and
reaches each gateway as `root@::1` through `ssh -W` on that connection. One
master connection keeps 32 polls from tripping sshd's `MaxStartups`. Gateway
host keys go to `/dev/null`. The caller needs keys for both the jumphost and
the gateways.

## Gateway session log

`gw-session-log` is a `pam_exec` hook (`session optional pam_exec.so quiet
/usr/local/sbin/gw-session-log` in `/etc/pam.d/sshd`). On each
`open_session` and `close_session` for a gateway login it appends a
tab-separated line to `/var/log/gateway-sessions.log`: UTC time, `open` or
`close`, login, UID (the tunnel port), `PAM_RHOST`, and its parent's pid,
which is the sshd process that owns the session and appears as `sshd[pid]`
in the journal. A gateway login has a UID of 20000-29999 and a name ending
in its MAC address (`-xx-xx-xx-xx-xx-xx` or 12 hex digits); some people's
logins also have UIDs in that range. The hook runs as root inside sshd, so
it must stay quick and always exit 0. It runs under `/bin/sh`.

`install-session-log.sh` (run as root on the jumphost) installs the hook,
the log, a logrotate file (monthly, 36 copies, `-YYYYMM.gz`) and the PAM
line. On the run that adds the PAM line it also turns the journal's sshd
lines up to that moment into log lines, using the same tests, and puts them
at the front of the log. It rewrites the log in place under `flock`, which
the hook also takes, so no line is lost meanwhile.

`gateway-sessions.sh` pairs each `open` with the `close` of the same login
and pid. An open with no close is `up` if that sshd pid still runs, else
`lost`; a close with no open (from before the log starts) shows `?` for the
open time. The journal and the hook can both record an event near the
install time, so duplicate (event, login, pid, hour) lines are dropped.
`-s` adds, per gateway, the session count, the average length of the closed
sessions, and the state now. "Up" means the tunnel port is listening
(`netstat -ln`, joined to `/etc/passwd` by UID as in `live-gateways.sh`),
so gateways connected since before the log began still show; their length
is `?`. A session that is open while the port isn't listening shows as
`no-tunnel`. A session open across the hook's install has no close line:
sshd reads its PAM config when the session starts.
`_report` does the work on the jumphost, sent over ssh with `declare -f`,
because it needs gawk's `mktime`, the jumphost's sshd pids, and the log.

The journal on the jumphost keeps sshd lines for only about two days:
journald keeps a separate 8 MB `user-<uid>.journal` for each gateway login,
and those fill its size limit.

## Gateway records

Each gateway login's home directory on the jumphost holds
`gateway_state.json`, a record of the gateway. `"source": "inventory"`
records come from `seed-gateway-state.sh`; a planned change to
ttn-multitech-cm will have gateways push `"source": "gateway"` records of
their own over their tunnel login, replacing the seeded one by `mv` (the
gateway owns the directory, so it can replace a file root owns).

`seed-gateway-state.sh` runs `ansible/seed.yml` through ttn-multitech-cm's
`bin/run`, which mounts `$PWD`, `$HOME` and `TTN_ORG`, so the play must be
under `$HOME`. The container has no git, so the script runs `git describe`
on the org repo itself and passes it in as `seed_config_version`. The play
adds the jumphost with `add_host` (port 22, the caller's `$USER`, no
`ProxyCommand`), rather than delegating from each gateway, because the
gateways' connection variables (`ansible_port`, `ansible_ssh_common_args`)
would otherwise apply to the jumphost. It never connects to a gateway. It
skips gateways whose `ssh_tunnel_remote_host` is another jumphost, logins
that don't end in a MAC address (old groups share the login `ttn`), and
logins missing from the jumphost's `/etc/passwd`, so it never creates a home
directory. Records are written with `force: false` unless `-f`.

Home directories become group `wheel`, mode 2750 (setgid, so files a
gateway writes later get group `wheel`); records are root-owned, 0640.
sshd's `StrictModes` accepts a home directory that isn't group-writable.
`.ssh` keeps its own mode and group.

`gateway-info.sh` runs a Python 3 `_report` on the jumphost (sent with
`declare -f`, as in `gateway-sessions.sh`). It selects logins the same way as
`gw-session-log`, reads each record it can (records it can't read count as
missing), and adds `now` (tunnel port listening) and `last_close` (from the
session log).

## How `kick-all-gateways.sh` works

`_kickgateway` does all its work in one `ssh -p <port> root@localhost` call
(`root@::1` through the jumphost with `-H`).
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
- A forwarder process (`pidof mp_pkt_fwd.usb mp_pkt_fwd.spi`, or `pidof
  station`) other than the one the pid file names means `orphan`, whatever
  the pid file says. The init scripts stop only the pid file's process.
- A log file older than 10 minutes means `hung`.
- On the packet forwarder only, a last log line ending in
  `ERROR: [main] failed to start the concentrator` (with or without a leading
  timestamp) turns `crashed` into `concentrator`.
- With an unknown transport, the script skips the forwarder checks above and
  reports `unknown-transport`. It takes no action unless `-R` or `-B` asks for
  a reboot.
- `/var/log` usage over 75% means `full`, whatever the transport.

`hung`, `full`, `concentrator`, `orphan`, `-R` and `-B` lead to `reboot`; other faults
run the init script's `restart`. `-Q` reports without acting.

The remote script prints its results as `@key=value` lines ended by `@end`,
then runs the action; anything after `@end` is the action's output.
`_formatgateway` on the jumphost side parses them. Output there with no
`@end` means the ssh failed.

Output is one line per gateway, fields joined by the `-f` separator (default
`": "`): login, port, `-s` stats, EUI, mLinux version, link, `-L` description,
status.

The link is the interface of the default route: `ethernet` (`eth*`),
`cellular` (`ppp*`, `wwan*`), `none`, or the interface name. `-s` counts rx
plus tx bytes on that interface. On ethernet it shows MB per month: the rate
since boot times 31 days. On cellular it shows only MB since the link came up,
because `ppp0`'s counts start again at each reconnect and the gateway has no
trustworthy record of when that was. The age of the `/sys/class/net` entry is
not one: entries made before the clock is set carry dates years off, and the
kernel can rebuild an entry with a new date.

`-o json` prints one JSON object per gateway per line, with every field
whatever `-s` and `-L` say, and `null` for missing values. A failed ssh gives
an object with `login`, `port`, `time` and `error` only.

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
