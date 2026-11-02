#!/bin/bash
# Snapshot one UE's uplink throughput and RTT to a sink UE, and append a labeled
# line to a report in /local/results. Use it to capture a baseline and then an
# under-attack sample for experiments that act on the radio rather than on a
# single flow (jamming, RACH flood): run it once before the attack and once
# during, with different labels, and compare.
#
# Usage:  sudo ./measure.sh <label> [ue] [sink]
# Example: sudo ./measure.sh baseline 1 2   (clean broker)
#          sudo ./measure.sh jammed   1 2   (while ./jam.sh runs)
set -euo pipefail
cd "$(dirname "$0")"
source ./lib-guard.sh

LABEL="${1:?usage: sudo ./measure.sh <label> [ue] [sink]}"
UE="${2:-1}"
SINK="${3:-2}"
PORT=5204

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
command -v iperf3 >/dev/null || { echo "Install iperf3: sudo apt-get install -y iperf3" >&2; exit 1; }
require_testbed
SINK_IP="$(require_ue_attached "$SINK")"
require_ue_attached "$UE" >/dev/null
require_target "$SINK_IP"

ip netns exec "ue$UE"   ip route replace default dev tun_srsue
ip netns exec "ue$SINK" ip route replace default dev tun_srsue

ip netns exec "ue$SINK" iperf3 -s -p "$PORT" -D 2>/dev/null || true
sleep 1
trap 'ip netns exec "ue'"$SINK"'" pkill -f "iperf3 -s" 2>/dev/null || true' EXIT

# Throughput (0.00 if the link is too jammed to connect).
TP="$(ip netns exec "ue$UE" iperf3 -c "$SINK_IP" -p "$PORT" --connect-timeout 3000 \
        -t 10 -J 2>/dev/null | python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin); print("%.2f"%(d["end"]["sum_received"]["bits_per_second"]/1e6))
except Exception:
    print("0.00")' || true)"

# RTT and loss.
read -r RTT LOSS <<<"$(ip netns exec "ue$UE" ping -n -c 10 -i 0.2 "$SINK_IP" 2>/dev/null | awk '
    /packet loss/ { for (i=1;i<=NF;i++) if ($i ~ /%$/) loss=$i }
    /rtt|round-trip/ { split($4,a,"/"); rtt=a[2] }
    END { print (rtt==""?"n/a":rtt), (loss==""?"n/a":loss) }' || true)"

mkdir -p /local/results
REPORT=/local/results/measure.csv
[ -f "$REPORT" ] || echo "timestamp,label,ue,sink,throughput_mbps,rtt_ms,loss" > "$REPORT"
echo "$(date -Is),$LABEL,ue$UE,ue$SINK,$TP,$RTT,$LOSS" | tee -a "$REPORT"
echo "Snapshot '$LABEL': UE$UE -> UE$SINK  ${TP} Mbit/s, RTT ${RTT} ms, loss ${LOSS}"
echo "Appended to $REPORT"
