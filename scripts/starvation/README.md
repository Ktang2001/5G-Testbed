# 5G testbed attack experiments

Measured demonstrations of three attacks on the isolated POWDER srsRAN ZMQ
testbed  **slice starvation**, **jamming**, and **flooding** (control-plane and
data-plane) each paired with the defense. This is defensive security research:
the point is to make each failure visible and show the mitigation.

| Experiment        | Script              | Layer          |
|-------------------|---------------------|----------------|
| Slice starvation  | `starvation-demo.sh`| scheduler/PRBs |
| Jamming           | `jam.sh`            | PHY (SINR)     |
| RACH flood        | `flood-rach.sh`     | control plane  |
| Data-plane flood  | `flood-data.sh`     | user plane     |

All scripts share `lib-guard.sh` and will not run anywhere but this testbed
(see **Safeguards** below).

## 1. Slice resource-starvation experiment

Shows how one slice saturating the shared cell can starve another of throughput
and latency, and therefore why the per-slice PRB guarantees in
[`config/gnb.yaml`](../../config/gnb.yaml) matter. The mitigation is
`min_prb_policy_ratio`.

## What it does

There is one gNB cell, so all three slices share one pool of PRBs:

| UE  | Slice | min PRB | max PRB |
|-----|-------|---------|---------|
| UE1 | eMBB  | 20%     | 100%    |
| UE2 | URLLC | 30%     | 100%    |
| UE3 | mMTC  | 0%      | 10%     |

The script drives the **attacker** slice (UE1/eMBB) to saturate the cell with
`iperf3`, and measures the **victim** slice (UE3/mMTC) throughput and RTT before
and during that load. mMTC has no PRB floor, so it starves first.

Bring up the gNB, all three UEs and the broker (see `../../powder-runbook.txt`),
then:

```bash
sudo apt-get install -y iperf3
cd /local/repository/scripts/starvation
sudo ./starvation-demo.sh            # attacker=UE1, victim=UE3, sink=UE2, 30s
sudo ./stop.sh                       # if you interrupt it
```

## 2. Jamming experiment

`attack-broker.py` is a drop-in replacement for `zmq-broker.py` that injects
Gaussian noise into the simulated IQ sample stream. The noise lives only inside
the GNU Radio flowgraph, so it degrades SINR exactly like an RF jammer **but
cannot reach any real radio**.

Start the gNB and the 3 UEs as usual, stop the normal broker, then:

```bash
cd /local/repository/scripts/starvation
./jam.sh both -3          # jam uplink+downlink, moderate power
# ./jam.sh dl 0           # downlink only, strong
# ./jam.sh ul -10         # uplink only, mild
```

Watch the gNB window (press `t`): BLER climbs, throughput falls, and under strong
jamming the UEs lose sync and re-attach. Press Enter in the jam window to stop,
then restart the normal `zmq-broker.py`. `jam_db` is noise amplitude in dB:
`-10` mild, `-3` moderate, `0` strong, `+6` severe. The defense discussion is
about detection (SINR/BLER monitoring) and resilience (coding, frequency agility);
in this sim you mainly observe the degradation curve vs `jam_db`.

## 3. Flooding experiments

### Control-plane: RACH flood (`flood-rach.sh`)

Launches many rogue srsUE instances with bogus, unprovisioned IMSIs. They
complete random access, fail authentication, get released and retry — sustaining
load on the random-access channel so legitimate UEs struggle to attach. This is
the deliberate form of the preamble collisions seen during bring-up.

It needs the broker running with enough attacker slots:

```bash
# in the broker window, instead of the normal broker:
ATTACK_SLOTS=16 python3 /local/repository/scripts/starvation/attack-broker.py

# then, in another window:
cd /local/repository/scripts/starvation
sudo ./flood-rach.sh 12 30          # 12 rogue UEs for 30s
```

While it runs, restart a legitimate UE and watch it take far longer to attach, or
fail. Defenses to discuss: RACH back-off, contention-resolution limits, and
per-RNTI rate limiting at the gNB.

### Data-plane: packet flood (`flood-data.sh`)

One UE blasts a victim UE with high-rate small UDP packets; a third UE probes the
victim's RTT and loss before and during:

```bash
sudo ./flood-data.sh 1 3 2 20       # attacker=UE1, victim=UE3, probe=UE2, 20s
```

The victim's RTT and loss jump during the flood. The mitigation is again slice
isolation — a PRB floor keeps the victim usable.

## Note on absolute numbers

The ZMQ-simulated RF caps throughput well below real radio, so read the
relative change (percent drop, RTT ratio), not the absolute Mbit/s.
