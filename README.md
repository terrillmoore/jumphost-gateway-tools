# jumphost-gateway-tools

Useful scripts for managing gateways configured using [conduit-mfg](https://github.com/terrillmoore/conduit-mfg) procedures

* `live-gateways.sh` displays a list of the gateways currently connected to the jumphost. Example:
   ```console
   $ ./live-gatewways.sh
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
   ```

   In the above, the packet forwarder for `ttn-ithaca-00-08-00-4a-2b-2b` has crashed, and is restarted. The packet forwarder of `ttn-ithaca-00-08-00-4a-37-6a` is discovered to have stopped, so it also is restarted.
   
   **Note:** it is a good idea to make sure that nobody is working on the packet forwarder locally when running this script, as they may have intentionally stopped the packet forwarder.
