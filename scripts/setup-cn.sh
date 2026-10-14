#!/bin/bash
set -ex
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y gnupg curl software-properties-common

# MongoDB (subscriber database)
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
systemctl restart open5gs-amfd open5gs-upfd

# Add test subscriber
curl -fsSL -o /usr/local/bin/open5gs-dbctl \
  https://raw.githubusercontent.com/open5gs/open5gs/main/misc/db/open5gs-dbctl
chmod +x /usr/local/bin/open5gs-dbctl
open5gs-dbctl add 999700000000001 465B5CE8B199B49FAA5F0A2EE238A6BC E8ED289DEBA952E4283B54E88E6183CA

# Internet access for UEs
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE

echo "CN SETUP DONE"
