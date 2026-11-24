# jumphost-gateway-tools

Useful scripts for managing gateways configured using [conduit-mfg](https://github.com/terrillmoore/conduit-mfg) procedures

* `live-gateways.sh` displays a list of the gateways currently connected to the jumphost. Example:
   ```console
   $ ./live-gateways.sh
   ttn-ithaca-00-08-00-4a-2b-2b	20008
   ttn-ithaca-00-08-00-4a-37-69	20017
   ttn-ithaca-00-08-00-4a-37-6a	20019
   $
   ```
   
* `kick-all-gateways.sh` iterates over all connected gateways and restarts the packet forwarder if it seems to be dead. It detects:
    1. stopped packet forwarders (e.g., due to administrative stops); 
    2. crashed packet forwarders (where the forwarder has exited but not through the normal administrative interface); and
    3. hung packet forwarders (where the forwarder is running, but has not updated the log file for 10 minutes.
    
   Here's an example:
   ```console
   $ ./kick-all-gateways.sh 
   ttn-ithaca-00-08-00-4a-2b-2b 20008: 00:80:00:00:00:00:FD:45: crashed, restarting
   sh: line 3: kill: (30650) - No such process
   Stopping ttn-packet-forwarder: start-stop-daemon: warning: failed to kill 30650: No such process
   OK
   Starting ttn-packet-forwarder: OK
   ttn-ithaca-00-08-00-4a-37-69 20017: 00:80:00:00:A0:00:1D:B2: ok
   ttn-ithaca-00-08-00-4a-37-6a 20019: 00:80:00:00:A0:00:1D:B3: stopped, restarting
   Stopping ttn-packet-forwarder: OK
   Starting ttn-packet-forwarder: OK
   ttn-ithaca-00-08-00-4a-2b-2b 20008: 00:80:00:00:00:00:FD:45: ok
   ttn-ithaca-00-08-00-4a-37-69 20017: 00:80:00:00:A0:00:1D:B2: ok
   ttn-ithaca-00-08-00-4a-37-6a 20019: 00:80:00:00:A0:00:1D:B3: ok
   ttn-ithaca-00-08-00-4a-37-71 20006: 00:80:00:00:A0:00:1D:AA: ok
   $ 
   ```

   In the above, the packet forwarder for `ttn-ithaca-00-08-00-4a-2b-2b` has crashed, and is restarted. The packet forwarder of `ttn-ithaca-00-08-00-4a-37-6a` is discovered to have stopped, so it also is restarted.
   
   **Note:** it is a good idea to make sure that nobody is working on the packet forwarder locally when running this script, as they may have intentionally stopped the packet forwarder.

   The script also runs from other machines; you need ssh keys for the jumphost and for the gateways. It reaches the gateways through `jumphost.ttni.tech` unless the gateway tunnels end on the machine it runs on. `-H {host}` names another jumphost, and `-l` makes it use the tunnels on the machine it runs on.

* `gateway-sessions.sh` shows when each gateway's ssh session to the jumphost opened and closed, one line per session: login, port, opened, closed (`up` if still open), length, remote address, then mLinux version, forwarder and link from the gateway's record (see `gateway-info.sh`), with `-L` the description. Times are UTC. On a terminal it prints a table with a header; in a pipe, or with `-f`, it joins the fields with the `-f` separator (default `': '`), as `kick-all-gateways.sh` does. `-o json` prints one JSON object per line, and arguments are regular expressions matched against the login (`18-c6` selects `ttn-nyc-00-08-00-4a-18-c6`). `-S` starts at a time, `-r` prints the log lines themselves, and `-s` prints one line per gateway instead: sessions, average length of the closed sessions, the record's fields, and last whether it is up now (tunnel port listening) and for how long, or when it went down. Example:
   ```console
   $ ./gateway-sessions.sh -s -L 37-6e
   ┌──────────────────────────────┬───────┬──────────┬─────────┬────────┬───────────┬──────────┬──────────────────────────────────────┬───────────┐
   │ LOGIN                        │ PORT  │ SESSIONS │ AVERAGE │ MLINUX │ FORWARDER │ LINK     │ DESCRIPTION                          │ NOW       │
   ├──────────────────────────────┼───────┼──────────┼─────────┼────────┼───────────┼──────────┼──────────────────────────────────────┼───────────┤
   │ ttn-ithaca-00-08-00-4a-37-6e │ 20015 │ 110      │ 15m19s  │ 5.3.31 │ basic     │ ethernet │ Tompkins County #5 (Coddington Road) │ up 18m26s │
   └──────────────────────────────┴───────┴──────────┴─────────┴────────┴───────────┴──────────┴──────────────────────────────────────┴───────────┘
   ```
   Like `kick-all-gateways.sh`, it runs on the jumphost or reaches `jumphost.ttni.tech` with ssh (`-H`, `-l`).

   It reads `/var/log/gateway-sessions.log` (and its monthly `.gz` copies, kept for 3 years), which a PAM hook, `gw-session-log`, writes each time a gateway's session opens or closes. Set it up once, as root on the jumphost:
   ```console
   $ sudo ./install-session-log.sh
   ```
   This installs the hook in `/usr/local/sbin`, adds it to `/etc/pam.d/sshd` (saving a copy of the old file), sets up monthly rotation in `/etc/logrotate.d/gateway-sessions`, and loads the sessions still in the journal (about two days) into the log.

* `gateway-info.sh` describes each gateway known to the jumphost, connected or not: login, port, up or down (and since when), where its record came from, description, mLinux version and forwarder. Patterns select gateways as for `kick-all-gateways.sh`; `-u` shows only the gateways that are up, `-d` only those that are down. On a terminal it prints a table with a header; in a pipe, or with `-f`, it prints the fields separated by tabs (or the `-f` separator). `-o json` prints the whole record. Example:
   ```console
   $ ./gateway-info.sh 37-6e
   ┌──────────────────────────────┬───────┬─────┬───────────┬──────────────────────────────────────┬────────┬───────────┐
   │ LOGIN                        │ PORT  │ NOW │ SOURCE    │ DESCRIPTION                          │ MLINUX │ FORWARDER │
   ├──────────────────────────────┼───────┼─────┼───────────┼──────────────────────────────────────┼────────┼───────────┤
   │ ttn-ithaca-00-08-00-4a-37-6e │ 20015 │ up  │ inventory │ Tompkins County #5 (Coddington Road) │ 5.3.31 │ basic     │
   └──────────────────────────────┴───────┴─────┴───────────┴──────────────────────────────────────┴────────┴───────────┘
   ```
   It reads `~<login>/gateway_state.json` on the jumphost, which `seed-gateway-state.sh` writes from an org inventory:
   ```console
   $ ./seed-gateway-state.sh -o ../org-ttn-ithaca-gateways
   ```
   This runs `ansible/seed.yml` in ttn-multitech-cm's container (`bin/run`, so it needs what an apply needs, plus sudo on the jumphost). It never connects to a gateway, so offline gateways get a record too. It doesn't replace a record that exists unless given `-f`; `-n` shows what it would change. It also sets each gateway's home directory on the jumphost to group `wheel`, mode 2750, so people in `wheel` can read the records.
