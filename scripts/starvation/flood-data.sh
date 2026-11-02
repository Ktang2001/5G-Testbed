#!/bin/bash
# Data-plane flood: one UE blasts a victim UE with high-rate small UDP packets,
# and we measure the victim's responsiveness (RTT and loss, probed from a third
# UE) before and during the flood.
#
# Usage:  sudo ./flood-data.sh [attacker_ue] [victim_ue] [probe_ue] [secs]
# Default: attacker=1 (eMBB)  victim=3 (mMTC)  probe=2 (URLLC)  20s
set -euo pipefail
cd "$(dirname "$0")"
source ./lib-guard.sh

ATTACKER="${1:-1}"
VICTIM="${2:-3}"
PROBE="${3:-2}"
SECS="${4:-20}"
PORT=5203

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
command -v iperf3 >/dev/null || { echo "Install iperf3: sudo apt-get install -y iperf3" >&2; exit 1; }
require_testbed
VICTIM_IP="$(require_ue_attached "$VICTIM")"
require_ue_attached "$ATTACKER" >/dev/null
require_ue_attached "$PROBE"   >/dev/null
require_target "$VICTIM_IP"

for n in "$ATTACKER" "$VICTIM" "$PROBE"; do
    ip netns exec "ue$n" ip route replace default dev tun_srsue
done

cleanup() {
    ip netns exec "ue$VICTIM"   pkill -f "iperf3 -s" 2>/dev/null || true
    ip netns exec "ue$ATTACKER" pkill -f "iperf3 -c" 2>/dev/null || true
}
trap cleanup EXIT

ip netns exec "ue$VICTIM" iperf3 -s -p "$PORT" -D
sleep 1

# probe <label>: ping victim from the probe UE, print "avg_rtt loss%".
probe() {
    ip netns exec "ue$PROBE" ping -n -c 10 -i 0.2 "$VICTIM_IP" 2>/dev/null | awk '
        /packet loss/ { for (i=1;i<=NF;i++) if ($i ~ /%$/) loss=$i }
        /rtt|round-trip/ { split($4,a,"/"); rtt=a[2] }
        END { print (rtt==""?"n/a":rtt), (loss==""?"n/a":loss) }'
}

echo "=== Data-plane flood: UE$ATTACKER -> UE$VICTIM ($VICTIM_IP), ${SECS}s ==="
read -r BASE_RTT BASE_LOSS <<<"$(probe)"
echo "baseline victim: RTT ${BASE_RTT} ms, loss ${BASE_LOSS}"

echo "Starting UDP flood (max packet rate, 64-byte payloads)..."
ip netns exec "ue$ATTACKER" iperf3 -u -c "$VICTIM_IP" -p "$PORT" \
    -b 0 -l 64 -t "$SECS" >/dev/null 2>&1 &
FLOOD_PID=$!
sleep 2

read -r ATK_RTT ATK_LOSS <<<"$(probe)"
echo "under flood victim: RTT ${ATK_RTT} ms, loss ${ATK_LOSS}"
wait "$FLOOD_PID" 2>/dev/null || true

mkdir -p /local/results
REPORT="/local/results/flood-data-$(date +%Y%m%d-%H%M%S).txt"
{
    echo "=================== RESULT ==================="
    echo "experiment : data-plane UDP flood"
    echo "when       : $(date -Is)"
    echo "attacker UE$ATTACKER -> victim UE$VICTIM ($VICTIM_IP), probe UE$PROBE, ${SECS}s"
    printf "victim UE%s RTT  : %7s -> %7s ms\n"  "$VICTIM" "$BASE_RTT" "$ATK_RTT"
    printf "victim UE%s loss : %7s -> %7s\n"     "$VICTIM" "$BASE_LOSS" "$ATK_LOSS"
    echo "A packet flood toward the victim inflates its RTT and loss. The defense"
    echo "is the same slice isolation lever: a PRB floor keeps the victim usable."
    echo "============================================="
} | tee "$REPORT"
echo "Report saved: $REPORT"
