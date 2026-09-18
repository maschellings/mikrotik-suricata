# Deploying on a MikroTik router (RouterOS native container + Portainer)

This guide walks through getting Docker running natively on a MikroTik
device via RouterOS's built-in container feature and MikroTik's
`docker-with-portainer` App, then deploying this repo as a Portainer
stack. It assumes an ARM64 CCR-series router (or similar) with an NVMe
or other disk attached for container storage, running a RouterOS
version that supports containers and the App store.

This is not the only way to run this project — any Docker host that
can reach your router's mirrored traffic works. This guide documents
the specific path that was actually tested end-to-end: Docker running
*inside* RouterOS itself, orchestrated via Portainer, with no separate
physical or virtual machine involved.

None of this requires manually creating a veth interface, a route, or
NAT rule for the Docker network yourself — RouterOS and its App system
create those automatically as part of deploying `docker-with-portainer`.
The steps below tell you what to check for, not what to build from
scratch.

## 1. Enable the container feature

From a terminal (Winbox's "New Terminal", or SSH):

```
/system device-mode update container=yes
```

RouterOS will ask for a physical confirmation (press the router's
reset button briefly, or hit Enter if connected locally/directly,
depending on your setup and architecture). This will likely reboot the
router — do this at a time a short network interruption is acceptable.

Confirm afterwards:

```
/system device-mode print
```

`container` should read `yes`.

## 2. Format a disk for container storage

If not already done, format your NVMe/SSD in Winbox:

- **Disk** menu → select your disk → **Format Drive** → filesystem
  `ext4` → **Start**

## 3. Configure the App system's disk, bridge, and router IP

- Sidebar → **App**
- A **Setup** wizard should appear (or find it under App settings) —
  it needs:
  1. **Apps Disk**: the disk you just formatted
  2. **Lan Bridge**: your main bridge interface
  3. **Router IP**: the IP address you use to manage the router (your
     management VLAN's address, not `0.0.0.0` or the factory default
     `192.168.88.1`)
- You can re-check these later under **App → Settings**.

## 4. Deploy the `docker-with-portainer` App

- In the **App** list, double-click **docker-with-portainer**
- Set:
  - **Enabled**: checked
  - **Network**: `internal`
  - **Network PVID**: `1` (default)
  - **Use HTTPS**: **unchecked** — leaving this checked triggers an
    automatic Let's Encrypt certificate request that goes through
    MikroTik's own cloud DDNS service to get a publicly reachable
    hostname pointed at your router, which is not something you want
    for an admin panel with full Docker control. Unchecking it keeps
    everything local (plain HTTP on your management network).
- Apply. `Status` should move to `downloading` then `running`.

This step creates two things automatically, which you'll rely on later
but never need to create yourself:

- A veth interface named `veth-app-docker-with-portainer`
- A static route for `172.18.0.0/24` (the App's `internal` Docker
  network) via that veth

## 5. Firewall: allow reaching the Docker network and the WAN

By default, RouterOS's typical inter-VLAN isolation rules will block
this new `172.18.0.0/16` network both ways. Add two Filter Rules
(**IP → Firewall → Filter Rules**), positioned *above* your general
isolation/deny rules:

**Rule 1 — let your management/admin VLAN reach the Docker network:**

- Chain: `forward`
- In. Interface: your management/admin VLAN (wherever you'll browse to
  Portainer from)
- Dst. Address: `172.18.0.0/16`
- Action: `accept`

**Rule 2 — let the Docker network reach the internet** (needed for
image pulls, `suricata-update`, apt, etc. during the build):

- Chain: `forward`
- In. Interface: `veth-app-docker-with-portainer`
- Out. Interface: your real WAN interface
- Action: `accept`

The `docker-with-portainer` App already sets up its own outbound NAT
(masquerade) rule automatically, so you don't need to add one.

## 6. Log into Portainer

Browse to `http://<Router IP>:9000`.

**Time-sensitive step:** Portainer locks itself out if no admin
account is created within about 5 minutes of first starting. If you
see a "timed out for security purposes" message, go back to
**App → docker-with-portainer → Restart** and try again immediately —
don't leave the tab idle before setting the password.

## 7. Open the `local` environment

From Portainer's home screen, click into the `local` Docker
environment (not just "Manage" from the environments list — click the
environment name itself to load its full sidebar).

## 8. Deploy the stack from this repository

**Stacks → Add stack**

- Name: `suricata-ids`
- Build method: **Repository**
- Repository URL: this repo's GitHub URL
- Repository reference: `refs/heads/main` (or leave default)
- Compose path: `docker-compose.yml`

**Deploy the stack.** Compose creates the `suricata-net` network for
you automatically at this point (the `docker-compose.yml` pins its
name explicitly, so it won't get a stack-name prefix like
`suricata-ids_suricata-net` — no manual network creation needed). The
first build compiles Suricata from source — expect 15–25 minutes.
Don't navigate away while it's still building; if your browser sleeps
mid-build, Portainer may report a spurious "unable to build image"
error even if the build actually succeeded in the background — check
**Images** afterwards for a `suricata-tzsp:latest` entry before
assuming it failed.

## 9. Note the container's IP address

**Containers → suricata-ids** — note its IP on `suricata-net` (e.g.
`172.19.0.2`). You won't route to this IP directly from RouterOS; it's
just useful for reference (see step 11).

## RouterOS-side wiring

## 10. Verify the automatic route to Portainer's network

**IP → Routes** — you should see a route for `172.18.0.0/24` via
`internal` (or similar), already active. This was created
automatically when you deployed the App in step 4 — don't create it
yourself. If it's missing, something went wrong earlier in steps 3–4.

## 11. Understand why the mangle rule targets the Docker host, not the container

Suricata's own `suricata-net` (e.g. `172.19.0.0/16`) is **not**
directly routable from RouterOS — it's a network nested one level
deeper inside the Docker daemon that itself lives inside the
`docker-with-portainer` App's container. Rather than trying to route
into it, this repo's `docker-compose.yml` publishes Suricata's UDP
port directly on the Docker host:

```yaml
ports:
  - "37008:37008/udp"
```

That Docker host is reachable at the same IP Portainer uses —
`172.18.0.2` in a typical setup (check yours in **App →
docker-with-portainer**, or ping it to confirm from a terminal). The
mangle rule below targets *that* IP, not the container's own
`suricata-net` address from step 9.

## 12. Add the mangle rule to mirror WAN traffic

**IP → Firewall → Mangle → Add**

- Chain: `forward`
- In. Interface: your real WAN interface
- Action: `sniff-tzsp`
- Sniff Target: `172.18.0.2:37008` (your Docker host IP + port 37008)

## Verifying it all works

From the Suricata container's console (**Containers → suricata-ids →
Console**):

```sh
tail -f /var/log/suricata/eve.json
```

From a different device on your network (not the router or the
Suricata container itself, so the traffic actually goes out the WAN):

```sh
curl -A "BlackSun" http://testmyids.com/
```

If everything is wired correctly, an `"event_type":"alert"` entry
should appear in `eve.json` within a second or two.