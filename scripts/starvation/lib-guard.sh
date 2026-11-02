#!/bin/bash
# Safeguards shared by every script in this directory.
#
# These refuse to run anywhere that is not THIS POWDER srsRAN ZMQ-simulated
# testbed, so the experiment cannot touch a real or production 5G network.
# Source this file ("source lib-guard.sh"); do not run it directly.

# Slice subnets of this testbed. Traffic is only ever generated toward these.
ALLOWED_SUBNETS=("10.45.0.0/16" "10.46.0.0/16" "10.47.0.0/16")

# require_testbed: abort unless we are on the simulated RAN node.
# The markers below exist together only on this testbed, never on real gear:
# a production gNB/UPF has no srsUE built from source, no POWDER mountpoint,
# and no network namespaces literally named ue1/ue2/ue3.
require_testbed() {
    local ok=1 why=""
    [ -x /opt/srsRAN_4G/build/srsue/src/srsue ]      || { ok=0; why+=" no-srsue"; }
    [ -x /opt/srsRAN_Project/build/apps/gnb/gnb ]    || { ok=0; why+=" no-gnb"; }
    [ -d /local/repository ]                          || { ok=0; why+=" no-powder-repo"; }
    for ns in ue1 ue2 ue3; do
        ip netns list 2>/dev/null | grep -qw "$ns"   || { ok=0; why+=" no-netns-$ns"; }
    done
    if [ "$ok" -ne 1 ]; then
        echo "REFUSING TO RUN: this is not the POWDER srsRAN ZMQ testbed (${why# })." >&2
        echo "Expected /opt/srsRAN_*, /local/repository and netns ue1/ue2/ue3." >&2
        echo "These scripts are for the isolated simulated-RF testbed only." >&2
        exit 1
    fi
}

# ip_in_allowed <ip>: succeed only if ip falls inside one ALLOWED_SUBNET.
ip_in_allowed() {
    python3 -I - "$1" "${ALLOWED_SUBNETS[@]}" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(2)
sys.exit(0 if any(ip in ipaddress.ip_network(n) for n in sys.argv[2:]) else 1)
PY
}

# require_target <ip>: abort unless ip is a testbed slice address.
require_target() {
    if ! ip_in_allowed "$1"; then
        echo "REFUSING: target '$1' is not inside a testbed slice subnet." >&2
        echo "Allowed only: ${ALLOWED_SUBNETS[*]}" >&2
        exit 1
    fi
}

# ue_ip <n>: print the tunnel IP that UE n currently holds (empty if none).
ue_ip() {
    ip netns exec "ue$1" ip -4 -o addr show tun_srsue 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1
}

# require_ue_attached <n>: abort unless UE n has a tunnel IP.
require_ue_attached() {
    local ip; ip="$(ue_ip "$1")"
    if [ -z "$ip" ]; then
        echo "UE$1 is not attached (no tun_srsue IP). Start the gNB, UEs and broker first." >&2
        exit 1
    fi
    echo "$ip"
}
