#!/bin/bash
# Stop any traffic generators the demo left running in the UE namespaces.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib-guard.sh
require_testbed
for n in 1 2 3; do
    ip netns exec "ue$n" pkill -f iperf3 2>/dev/null || true
done
echo "Stopped iperf3 in ue1/ue2/ue3."
