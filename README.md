# mikrotik-suricata

Suricata IDS built from source, wired up to ingest a **TZSP-mirrored**
traffic stream from a MikroTik RouterOS device (e.g. a CCR series
router) via a `sniff-tzsp` mangle rule, no dedicated span port or
hardware TAP required.

Built and tested on a MikroTik CCR2116 (ARM64) running Docker natively
through RouterOS's container feature, with the container orchestrated
via Portainer. Should work on any arm64/amd64 Docker host with a
RouterOS device mirroring traffic to it.

## Why this exists

RouterOS can mirror routed traffic to an external target using
`action=sniff-tzsp` in a mangle rule. The receiving end gets a UDP
stream of TZSP-encapsulated packets, a format Suricata can't read
directly. This project decodes that stream and feeds it into Suricata
as if it were a live interface:

```
WAN traffic (mirrored)
        │  RouterOS mangle: action=sniff-tzsp
        ▼
   UDP:37008 (TZSP)
        │
   tzsp2pcap  ──decodes──►  tcpreplay  ──injects──►  veth-tzsp0
                                                          │
                                                    (veth pair)
                                                          │
                                                     veth-tzsp1
                                                          │
                                                      Suricata
                                                    (af-packet)
```

`tzsp2pcap` and `tcpreplay` never touch a real NIC, the veth pair is
just an in-container pipe, isolated from the container's actual
network interface.

## What's in the image

- Suricata built from the latest source tarball on
  openinfosecfoundation.org (auto-detected at build time see the
  `LATEST_FILE` logic in the Dockerfile), with a Rust toolchain
  installed via rustup just for the build and removed afterwards
  (Debian's packaged Rust is too old for current Suricata releases).
- `tzsp2pcap` (https://github.com/thefloweringash/tzsp2pcap), compiled
  from source.
- Emerging Threats Open ruleset, refreshed via `suricata-update` on
  every container start.
- A few `suricata.yaml` adjustments baked into the image (see
  "Configuration changes" below).

## Configuration changes baked into the image

| Change | Why |
|---|---|
| `af-packet` interface `eth0` → `veth-tzsp1` | Suricata needs to listen on the decoded side of the veth pair, not a real NIC. |
| `checksum-checks: no` on that interface | Mirrored packets never carry a valid hardware-offloaded checksum, so Suricata would otherwise flag every packet as `SURICATA TCPv4 invalid checksum`. |
| `stats: enabled: no` + the `eve-log` `- stats:` sub-type commented out | Disables the periodic stats dump entirely — it's noise for a home/small IDS deployment and the eve-log stats sub-type errors out at startup if left enabled while the global stats block is off. |
| `threshold-file:` uncommented | Enables `/etc/suricata/threshold.config` for future rule tuning (suppressing noisy signatures). |
| `eve-log` → `types:` trimmed to `- alert:` only | `eve.json` otherwise fills up with `flow`, `dns`, `http`, `tls`, etc. records for every connection, most of which you don't want for a lightweight alert-only setup. See `scripts/comment_eve_types.py`. |

`start.sh` (the container entrypoint) additionally:

- Detects the host's current public IPv4/IPv6 (via ipify.org) and adds
  it to `HOME_NET` at startup, alongside the RFC1918 ranges. This
  matters because the mirrored traffic is captured on the WAN side
  without the public IP in `HOME_NET`, Suricata can't correctly tag
  traffic direction (`to_server` / `to_client`) for a lot of rules.
- Re-checks the public IP every 15 minutes and restarts Suricata (via
  the container's restart policy) if it changed, so `HOME_NET` doesn't
  go stale on a dynamic IP connection.
- Creates the `veth-tzsp0`/`veth-tzsp1` pair with MTU 65535 (mirrored
  frames can occasionally arrive larger than a typical 1500/9000 MTU
  depending on what the router captured before segmentation, a lower
  MTU here produces `Message too long (errno=90)` warnings from
  tcpreplay).
- Runs `suricata-update` before starting.

## RouterOS side

You need a mangle rule mirroring your WAN interface to wherever this
container's port 37008/udp is reachable:

```
/ip firewall mangle add chain=forward in-interface=<your-wan-interface> \
    action=sniff-tzsp sniff-target=<docker-host-ip>:37008 \
    comment="Suricata IDS: TZSP mirror"
```

If your Docker host's own container network isn't directly routable
from RouterOS (common when running Docker nested inside a RouterOS
container/App), publish the port on the host instead of relying on a
route into the overlay network — see the `ports:` mapping in
`docker-compose.yml`. Point `sniff-target` at the Docker host's
routable IP, not the container's internal overlay IP.

**Running this natively on the router itself, via RouterOS's container
feature and the `docker-with-portainer` App?** That's the setup this
repo was actually built and tested against — see
[docs/INSTALL.md](docs/INSTALL.md) for the full walkthrough: enabling
containers, the App's disk/network setup, the firewall rules needed to
reach Portainer and the Docker network, creating the `suricata-net`
network, and deploying this repo as a Portainer stack straight from
GitHub.

## Building

```sh
docker build -t suricata-tzsp:latest .
```

Build time is roughly 15–25 minutes on a modest ARM64 host — most of
it is compiling Suricata and its Rust components from source.

## Running

```sh
docker compose up -d
```

or deploy `docker-compose.yml` directly as a Portainer stack.

Required capabilities: `NET_ADMIN` and `NET_RAW` (needed to create the
veth pair and run Suricata in af-packet mode).

## Known limitations / things to improve

-  No automated blocking/response yet, this is IDS-only by design
      (detect, don't touch the firewall automatically), but a
      Telegram/webhook alerting script reading `eve.json` would be a
      natural next step.
- The `sed`/`awk` config patches in the Dockerfile are anchored to
      the structure of the Suricata-generated default `suricata.yaml`
      for the version fetched at build time. A future Suricata release
      changing that structure could silently break one of the patches
      — worth adding a post-build sanity check (`grep` assertions)
      that fails the build loudly instead.
- `HOME_NET` currently only tracks a single public IPv4/IPv6 pair;
      multi-WAN setups aren't handled.
-  No log rotation configured for `eve.json` inside the container,
      mount `/var/log/suricata` to a volume if you want persistence
      and add rotation on the host side.

## License

This repository (the Dockerfile, `start.sh`, `comment_eve_types.py`,
and `docker-compose.yml`) is licensed under the
[GNU Affero General Public License v3.0](LICENSE).

Note that AGPLv3's key obligation — providing source to anyone who
interacts with the software over a network — applies to the code in
*this* repository. It does not relicense Suricata itself (GPLv2),
tzsp2pcap, or the Emerging Threats Open ruleset, none of which are
vendored here; the Dockerfile only fetches and builds them from their
own upstream sources at build time, under their own respective
licenses.

## Credits
 
This project came out of a long, iterative debugging session. The
kind where you think you're an hour from done and you're actually
still eight hours out. Getting Suricata to actually see traffic
mirrored from inside a RouterOS container turned into a real
troubleshooting marathon: CRLF line endings silently breaking a shell
script, `sed` patterns matching the wrong line three times over, a
network routing problem caused by Docker running nested two layers
deep inside RouterOS's own container system, an MTU ceiling that only
showed up once real WAN traffic hit it, and a Suricata point release
shipping mid-project that had to be handled without breaking the
build.
 
The core idea — decoding TZSP-mirrored traffic with `tzsp2pcap` and
`tcpreplay` to feed Suricata — isn't original to this repo; it follows
the same shape documented by
[filip-lebiecki/suricata](https://github.com/filip-lebiecki/suricata)
(see Dependencies below). This project reimplements that idea for a
different environment: Docker running natively inside RouterOS itself,
rather than on a separate Linux box.
 
## Dependencies
 
- [Suricata](https://suricata.io/) / OISF — the IDS engine itself,
  built from source in the Dockerfile
- [tzsp2pcap](https://github.com/thefloweringash/tzsp2pcap) by
  thefloweringash — decodes the TZSP stream from RouterOS
- [Emerging Threats Open](https://rules.emergingthreats.net/) —
  the ruleset used for detection
