#!/bin/bash
set -ex
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y gnupg curl software-properties-common python3-yaml

# MongoDB 
curl -fsSL https://www.mongodb.org/static/pgp/server-6.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-6.0.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/mongodb-6.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" \
  > /etc/apt/sources.list.d/mongodb-org-6.0.list
apt-get update
apt-get install -y mongodb-org
systemctl enable --now mongod

# Open5GS
add-apt-repository -y ppa:open5gs/latest
apt-get update
apt-get install -y open5gs

# Bind AMF (N2) and UPF (N3) to the LAN IP
sed -i '/ngap:/,/address:/ s/address: 127.0.0.5/address: 10.10.1.1/' /etc/open5gs/amf.yaml
sed -i '/gtpu:/,/address:/ s/address: 127.0.0.7/address: 10.10.1.1/' /etc/open5gs/upf.yaml

# Network slicing: 3 slices in AMF, SMF, UPF
python3 - <<'EOF'
import yaml
SLICES = [  # (sst, dnn, subnet, gateway, tun device)
    (1, "internet", "10.45.0.0/16", "10.45.0.1", "ogstun"),
    (2, "urllc",    "10.46.0.0/16", "10.46.0.1", "ogstun2"),
    (3, "iot",      "10.47.0.0/16", "10.47.0.1", "ogstun3"),
]

def edit(path, fn):
    with open(path) as f:
        cfg = yaml.safe_load(f)
    fn(cfg)
    with open(path, "w") as f:
        yaml.safe_dump(cfg, f, sort_keys=False)

edit("/etc/open5gs/amf.yaml", lambda c: c["amf"]["plmn_support"][0].update(
    s_nssai=[{"sst": s, "sd": "000001"} for s, *_ in SLICES]))
edit("/etc/open5gs/smf.yaml", lambda c: c["smf"].update(
    session=[{"subnet": n, "gateway": g, "dnn": d} for _, d, n, g, _ in SLICES]))
edit("/etc/open5gs/upf.yaml", lambda c: c["upf"].update(
    session=[{"subnet": n, "gateway": g, "dnn": d, "dev": t} for _, d, n, g, t in SLICES]))
EOF

# Extra tunnel interfaces for the URLLC and mMTC slices
ip tuntap add name ogstun2 mode tun || true
ip tuntap add name ogstun3 mode tun || true
ip addr add 10.46.0.1/16 dev ogstun2 || true
ip addr add 10.47.0.1/16 dev ogstun3 || true
ip link set ogstun2 up
ip link set ogstun3 up

systemctl restart open5gs-amfd open5gs-smfd open5gs-upfd


curl -fsSL -o /usr/local/bin/open5gs-dbctl \
  https://raw.githubusercontent.com/open5gs/open5gs/main/misc/db/open5gs-dbctl
chmod +x /usr/local/bin/open5gs-dbctl

K=465B5CE8B199B49FAA5F0A2EE238A6BC
OPC=E8ED289DEBA952E4283B54E88E6183CA
open5gs-dbctl add_ue_with_slice 999700000000001 $K $OPC internet 1 000001
open5gs-dbctl add_ue_with_slice 999700000000002 $K $OPC urllc    2 000001
open5gs-dbctl add_ue_with_slice 999700000000003 $K $OPC iot      3 000001

# Internet access for UEs
sysctl -w net.ipv4.ip_forward=1
for net in 10.45.0.0/16 10.46.0.0/16 10.47.0.0/16; do
  iptables -t nat -A POSTROUTING -s $net ! -o ogstun+ -j MASQUERADE
done

echo "CN SETUP DONE"
