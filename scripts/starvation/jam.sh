#!/bin/bash
# Run the broker in JAMMING mode: inject simulated noise into the ZMQ sample
# stream so the UEs' SINR drops. Start the gNB and the 3 UEs first, then run
# this INSTEAD of the normal zmq-broker.py (stop that one first).
#
# Usage:  ./jam.sh [ul|dl|both] [jam_db]
# Default: both, -3 dB.  Higher (less negative) jam_db = stronger jamming:
#   -10 mild, -3 moderate, 0 strong, +6 severe.
#
# Watch the effect in the gNB window (type 't' for metrics): BLER rises,
# throughput falls, and with strong jamming UEs lose sync and re-attach.
# Stop jamming by pressing Enter here and restarting the normal broker.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib-guard.sh
require_testbed

export JAM_TARGET="${1:-both}"
export JAM_DB="${2:--3}"

echo "Stopping any plain broker..."
pkill -f zmq-broker.py 2>/dev/null || true
sleep 1
echo "Starting jamming broker (target=$JAM_TARGET, ${JAM_DB} dB)..."
exec python3 ./attack-broker.py
