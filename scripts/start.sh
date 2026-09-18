#!/bin/sh
# Entrypoint for the Suricata + TZSP container.
#
# 1. Detects the current public IPv4/IPv6 and injects it into HOME_NET
#    alongside the private ranges, so Suricata correctly tags direction
#    for traffic mirrored from the WAN interface.
# 2. Creates a veth pair used purely as a local pipe: tzsp2pcap decodes
#    the TZSP stream and tcpreplay feeds it in on one end, Suricata
#    listens on the other end in af-packet mode.
# 3. Refreshes Emerging Threats Open rules on every start.
# 4. Watches for WAN IP changes every 15 minutes and restarts Suricata
#    (via the container's restart policy) so HOME_NET stays accurate.
set -e

WAN4=$(curl -s -4 --max-time 5 https://api.ipify.org || true)
WAN6=$(curl -s -6 --max-time 5 https://api64.ipify.org || true)

HOMENET="192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
[ -n "$WAN4" ] && HOMENET="$HOMENET,$WAN4/32"
[ -n "$WAN6" ] && HOMENET="$HOMENET,$WAN6/128"

sed -i "s|HOME_NET:.*|HOME_NET: \"[$HOMENET]\"|" /etc/suricata/suricata.yaml
echo "HOME_NET updated: [$HOMENET]"

ip link add veth-tzsp0 type veth peer name veth-tzsp1
ip link set veth-tzsp0 mtu 65535
ip link set veth-tzsp1 mtu 65535
ip link set veth-tzsp0 up
ip link set veth-tzsp1 up

suricata-update

# Background watcher: if the public IPv4 changes, kill Suricata so the
# container's restart policy (e.g. `restart: unless-stopped`) brings it
# back up with a freshly detected HOME_NET.
(
  while true; do
    sleep 900
    N=$(curl -s -4 --max-time 5 https://api.ipify.org || true)
    if [ "$N" != "$WAN4" ]; then
      echo "WAN IP changed ($WAN4 -> $N), restarting container"
      pkill suricata
      exit 0
    fi
  done
) &

# Background watcher: refresh ET Open rules every 6 hours and hot-reload
# them into the running Suricata process via its unix-socket control
# interface, no restart needed.
(
  while true; do
    sleep 21600
    echo "Refreshing Suricata rules..."
    suricata-update
    suricatasc -c "reload-rules"
  done
) &

tzsp2pcap -f | tcpreplay --topspeed -i veth-tzsp0 - &

exec suricata -c /etc/suricata/suricata.yaml -i veth-tzsp1 --runmode=single
