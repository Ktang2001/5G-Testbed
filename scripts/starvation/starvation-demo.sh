#!/bin/bash
# Slice resource-starvation demonstration for the POWDER srsRAN ZMQ testbed.
#
# One slice (the "attacker", eMBB/UE1 by default) is driven to saturate the
# single shared cell's PRBs. We measure a "victim" slice (mMTC/UE3 by default)
# before and during that load to show how much throughput and latency it loses.
# The result illustrates why the gNB's per-slice min_prb_policy_ratio
# guarantees exist: mMTC is capped at 10% PRB, so it starves first.
#
# This is a measured, time-bounded experiment, not an open-ended flood, and it
# only runs on this isolated simulated testbed (see lib-guard.sh).
#
# Usage:  sudo ./starvation-demo.sh [attacker_ue] [victim_ue] [sink_ue] [attack_secs]
# Default: attacker=1 (eMBB)  victim=3 (mMTC)  sink=2 (URLLC)  attack=30s
set -euo pipefail
cd "$(dirname "$0")"
source ./lib-guard.sh

ATTACKER="${1:-1}"
VICTIM="${2:-3}"
SINK="${3:-2}"
ATTACK_SECS="${4:-30}"
MEAS_SECS=10                 # length of each victim measurement
ATTACK_STREAMS=4             # parallel TCP streams the attacker opens
PORT_V=5201                  # sink port for the victim flow
PORT_A=5202                  # sink port for the attacker flow

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
command -v iperf3 >/dev/null || { echo "Install iperf3: sudo apt-get install -y iperf3" >&2; exit 1; }

require_testbed
SINK_IP="$(require_ue_attached "$SINK")"
require_ue_attached "$ATTACKER" >/dev/null
require_ue_attached "$VICTIM"  >/dev/null
require_target "$SINK_IP"       # the only address we send traffic to

echo "=== Slice starvation demo ==="
echo "attacker = UE$ATTACKER   victim = UE$VICTIM   sink = UE$SINK ($SINK_IP)"
echo "attack duration = ${ATTACK_SECS}s, each measurement = ${MEAS_SECS}s"
echo

# Make sure every UE can route across slices to the sink (idempotent).
for n in "$ATTACKER" "$VICTIM" "$SINK"; do
    ip netns exec "ue$n" ip route replace default dev tun_srsue
done

cleanup() {
    ip netns exec "ue$SINK" pkill -f "iperf3 -s" 2>/dev/null || true
    ip netns exec "ue$ATTACKER" pkill -f "iperf3 -c" 2>/dev/null || true
    ip netns exec "ue$VICTIM"  pkill -f "iperf3 -c" 2>/dev/null || true
}
trap cleanup EXIT

# Start two iperf3 sinks inside the sink UE (one per flow, so they don't queue).
ip netns exec "ue$SINK" iperf3 -s -p "$PORT_V" -D
ip netns exec "ue$SINK" iperf3 -s -p "$PORT_A" -D
sleep 1

# mbps <iperf3-json>: extract receiver throughput in Mbit/s (0 on failure).
mbps() {
    python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin); print("%.2f"%(d["end"]["sum_received"]["bits_per_second"]/1e6))
except Exception:
    print("0.00")'
}

measure_victim() {   # prints "<mbps> <avg_rtt_ms>"
    local tp rtt
    tp="$(ip netns exec "ue$VICTIM" iperf3 -c "$SINK_IP" -p "$PORT_V" \
            -t "$MEAS_SECS" -J 2>/dev/null | mbps)"
    rtt="$(ip netns exec "ue$VICTIM" ping -n -c 5 -i 0.2 "$SINK_IP" 2>/dev/null \
            | awk -F'/' 'END{print ($5==""?"n/a":$5)}')"
    echo "$tp $rtt"
}

echo "[1/3] Baseline: victim slice alone (no competing load)..."
read -r BASE_TP BASE_RTT <<<"$(measure_victim)"
echo "      throughput ${BASE_TP} Mbit/s   avg RTT ${BASE_RTT} ms"
echo

echo "[2/3] Starting attacker load on UE$ATTACKER for ${ATTACK_SECS}s..."
ip netns exec "ue$ATTACKER" iperf3 -c "$SINK_IP" -p "$PORT_A" \
    -t "$ATTACK_SECS" -P "$ATTACK_STREAMS" -J >/tmp/starve-attacker.json 2>/dev/null &
ATTACK_PID=$!
sleep 2    # let the attacker ramp up and claim PRBs

echo "[3/3] Measuring victim slice while under load..."
read -r ATK_TP ATK_RTT <<<"$(measure_victim)"
echo "      throughput ${ATK_TP} Mbit/s   avg RTT ${ATK_RTT} ms"
wait "$ATTACK_PID" 2>/dev/null || true
echo

# Report (printed and saved to /local/results for export).
DROP="$(python3 -I -c "b=$BASE_TP or 0; a=$ATK_TP or 0; print('%.0f'%(100*(b-a)/b) if b>0 else 'n/a')")"
mkdir -p /local/results
REPORT="/local/results/starvation-$(date +%Y%m%d-%H%M%S).txt"
{
    echo "=================== RESULT ==================="
    echo "experiment : slice starvation"
    echo "when       : $(date -Is)"
    echo "attacker UE$ATTACKER -> sink UE$SINK ($SINK_IP), victim UE$VICTIM, attack ${ATTACK_SECS}s"
    printf "victim UE%s throughput : %7s -> %7s Mbit/s  (%s%% lost)\n" \
        "$VICTIM" "$BASE_TP" "$ATK_TP" "$DROP"
    printf "victim UE%s avg RTT     : %7s -> %7s ms\n" \
        "$VICTIM" "$BASE_RTT" "$ATK_RTT"
    echo "---------------------------------------------"
    echo "Interpretation: the single cell's PRBs are shared across slices."
    echo "When UE$ATTACKER saturates them, the gNB scheduler allocates per the"
    echo "slice min/max PRB ratios in config/gnb.yaml. mMTC (max 10% PRB) has no"
    echo "floor, so it starves; raising its min_prb_policy_ratio is the defense."
    echo "============================================="
} | tee "$REPORT"
cp -f /tmp/starve-attacker.json "${REPORT%.txt}-attacker.json" 2>/dev/null || true
echo "Report saved: $REPORT"
