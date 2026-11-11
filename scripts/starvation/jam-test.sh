#!/bin/bash
# One-command jamming test with a paired, computed report (like flood-data.sh).
# Measures a UE's link, injects noise, measures again, and writes a single
# jamming-<timestamp>.txt with baseline -> jammed and the throughput lost.
#
# PREREQUISITE: the NORMAL broker (zmq-broker.py) must be running and the UEs
# attached when you start this. The script stops that broker, runs the jammer
# in the background for the jammed sample, then stops the jammer. It does NOT
# restart the normal broker - do that yourself afterward so the UEs recover.
#
# Usage:  sudo ./jam-test.sh [ue] [sink] [jam_target] [jam_db]
# Default: ue=1 sink=2 target=both jam_db=-6
set -euo pipefail
cd "$(dirname "$0")"
source ./lib-guard.sh

UE="${1:-1}"
SINK="${2:-2}"
JAM_TARGET="${3:-both}"
JAM_DB="${4:--6}"
PORT=5205

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
command -v iperf3 >/dev/null || { echo "Install iperf3: sudo apt-get install -y iperf3" >&2; exit 1; }
require_testbed
SINK_IP="$(require_ue_attached "$SINK")"
require_ue_attached "$UE" >/dev/null
require_target "$SINK_IP"
pgrep -f zmq-broker.py >/dev/null || {
    echo "The normal broker (zmq-broker.py) must be running first." >&2; exit 1; }

ip netns exec "ue$UE"   ip route replace default dev tun_srsue
ip netns exec "ue$SINK" ip route replace default dev tun_srsue
ip netns exec "ue$SINK" iperf3 -s -p "$PORT" -D 2>/dev/null || true

JAM_PID=""
cleanup() {
    [ -n "$JAM_PID" ] && kill "$JAM_PID" 2>/dev/null || true
    ip netns exec "ue$SINK" pkill -f "iperf3 -s" 2>/dev/null || true
}
trap cleanup EXIT

# snapshot: prints "<mbps> <rtt_ms> <loss>" for UE->SINK (0.00/n-a if unreachable).
snapshot() {
    local tp rtt loss
    tp="$(ip netns exec "ue$UE" iperf3 -c "$SINK_IP" -p "$PORT" --connect-timeout 3000 \
            -t 10 -J 2>/dev/null | python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin); print("%.2f"%(d["end"]["sum_received"]["bits_per_second"]/1e6))
except Exception:
    print("0.00")' || true)"
    read -r rtt loss <<<"$(ip netns exec "ue$UE" ping -n -c 10 -i 0.2 "$SINK_IP" 2>/dev/null | awk '
        /packet loss/ { for (i=1;i<=NF;i++) if ($i ~ /%$/) l=$i }
        /rtt|round-trip/ { split($4,a,"/"); r=a[2] }
        END { print (r==""?"n/a":r), (l==""?"n/a":l) }' || true)"
    echo "$tp ${rtt:-n/a} ${loss:-n/a}"
}

echo "[1/2] Baseline (clean link)..."
read -r BASE_TP BASE_RTT BASE_LOSS <<<"$(snapshot)"
echo "      ${BASE_TP} Mbit/s, RTT ${BASE_RTT} ms, loss ${BASE_LOSS}"

echo "[2/2] Starting jammer (target=$JAM_TARGET, ${JAM_DB} dB) and re-measuring..."
pkill -f zmq-broker.py 2>/dev/null || true
sleep 1
JAM_TARGET="$JAM_TARGET" JAM_DB="$JAM_DB" \
    python3 ./attack-broker.py </dev/null >/tmp/jam-broker.log 2>&1 &
JAM_PID=$!
sleep 6    # let the noise take hold
read -r JAM_TP JAM_RTT JAM_LOSS <<<"$(snapshot)"
echo "      ${JAM_TP} Mbit/s, RTT ${JAM_RTT} ms, loss ${JAM_LOSS}"

DROP="$(python3 -I -c "b=$BASE_TP or 0; a=$JAM_TP or 0; print('%.0f'%(100*(b-a)/b) if b>0 else 'n/a')")"
mkdir -p /local/results
REPORT="/local/results/jamming-$(date +%Y%m%d-%H%M%S).txt"
{
    echo "=================== RESULT ==================="
    echo "experiment : RF jamming (simulated noise injection)"
    echo "when       : $(date -Is)"
    echo "link UE$UE -> sink UE$SINK ($SINK_IP), jam target=$JAM_TARGET, ${JAM_DB} dB"
    printf "throughput : %7s -> %7s Mbit/s  (%s%% lost)\n" "$BASE_TP" "$JAM_TP" "$DROP"
    printf "avg RTT    : %7s -> %7s ms\n" "$BASE_RTT" "$JAM_RTT"
    printf "loss       : %7s -> %7s\n"    "$BASE_LOSS" "$JAM_LOSS"
    echo "Gaussian noise injected into the IQ stream drops SINR below what the"
    echo "modulation/coding can decode, so the link collapses. Defense is detection"
    echo "(SINR/BLER monitoring) and resilience (coding, frequency agility)."
    echo "============================================="
} | tee "$REPORT"
echo "Report saved: $REPORT"
echo "NOTE: jammer stopped. Restart the normal broker so the UEs recover:"
echo "      python3 /local/repository/scripts/zmq-broker.py"
