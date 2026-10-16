#!/bin/bash
set -ex
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y build-essential cmake git pkg-config libfftw3-dev libmbedtls-dev \
  libsctp-dev libyaml-cpp-dev libgtest-dev libzmq3-dev libboost-program-options-dev \
  libconfig++-dev gnuradio

cd /opt

# srsRAN Project (gNB)
git clone --depth 1 -b release_24_10_1 https://github.com/srsran/srsRAN_Project.git
cd srsRAN_Project && mkdir build && cd build
cmake .. -DENABLE_ZEROMQ=ON -DENABLE_EXPORT=ON
make -j"$(nproc)" gnb
cd /opt

# srsRAN 4G (srsUE)
git clone --depth 1 https://github.com/srsran/srsRAN_4G.git
cd srsRAN_4G && mkdir build && cd build
cmake .. -DENABLE_ZEROMQ=ON
make -j"$(nproc)" srsue

# Network namespaces for the 3 UEs
for i in 1 2 3; do ip netns add ue$i || true; done

echo "RAN SETUP DONE"
