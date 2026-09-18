FROM debian:bookworm-slim

# --- Build dependencies + latest Suricata source + tzsp2pcap -------------
RUN apt-get update && apt-get install -y \
    build-essential libpcap-dev libnet1-dev libyaml-0-2 libyaml-dev \
    zlib1g zlib1g-dev libcap-ng-dev libcap-ng0 libmagic-dev \
    libjansson-dev libpcre2-dev pkg-config \
    python3 python3-yaml python3-setuptools \
    wget curl git iproute2 tcpreplay jq ca-certificates && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    . "$HOME/.cargo/env" && \
    LATEST_FILE=$(curl -s https://www.openinfosecfoundation.org/download/ | \
        grep -oE 'suricata-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' | \
        sort -V | uniq | tail -1) && \
    echo "Suricata version detected: $LATEST_FILE" && \
    wget https://www.openinfosecfoundation.org/download/$LATEST_FILE && \
    tar xzf $LATEST_FILE && \
    cd $(basename $LATEST_FILE .tar.gz) && \
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var && \
    make && make install-full && \
    cd / && rm -rf suricata-*/ suricata-*.tar.gz && \
    git clone https://github.com/thefloweringash/tzsp2pcap.git /tmp/tzsp2pcap && \
    cd /tmp/tzsp2pcap && make && make install && \
    apt-get purge -y build-essential git wget && apt-get autoremove -y && \
    rm -rf /tmp/tzsp2pcap /var/lib/apt/lists/* "$HOME/.rustup" "$HOME/.cargo"

# --- suricata.yaml adjustments -------------------------------------------
# Point af-packet at the internal veth pair instead of eth0, and disable
# checksum validation (mirrored traffic never carries a valid hardware
# checksum, so this avoids a flood of false-positive "invalid checksum"
# alerts).
RUN awk 'BEGIN{in_block=0} \
    /^af-packet:/{in_block=1} \
    in_block && !/^af-packet:/ && /^[^ ]/{in_block=0} \
    { \
      if(in_block && /interface: eth0/){sub(/eth0/,"veth-tzsp1")} \
      print; \
      if(in_block && /interface: veth-tzsp1/){print "    checksum-checks: no"} \
    }' /etc/suricata/suricata.yaml > /tmp/s.yaml && mv /tmp/s.yaml /etc/suricata/suricata.yaml

# Disable the periodic stats.log dump.
RUN sed -i '/^stats:/,/enabled:/ s/enabled: yes/enabled: no/' /etc/suricata/suricata.yaml

# The eve-log `- stats:` sub-type depends on the global stats block above;
# leaving it enabled while stats are globally disabled makes Suricata
# refuse to start. Comment it out (context-anchored, not by line number).
RUN sed -i -z 's/\( *\)- stats:\n\( *\)totals: yes       # stats for all threads merged together/\1#- stats:\n\2totals: yes       # stats for all threads merged together/' /etc/suricata/suricata.yaml

# Enable the threshold file (used for rule tuning later).
RUN sed -i 's|^# threshold-file: /etc/suricata/threshold.config|threshold-file: /etc/suricata/threshold.config|' /etc/suricata/suricata.yaml

# Trim eve-log types down to `- alert:` only (drops flow/dns/http/tls/...
# noise from eve.json). See scripts/comment_eve_types.py for details.
COPY scripts/comment_eve_types.py /tmp/comment_eve_types.py
RUN python3 /tmp/comment_eve_types.py /etc/suricata/suricata.yaml && \
    rm /tmp/comment_eve_types.py

# --- Entrypoint ------------------------------------------------------------
COPY scripts/start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]
