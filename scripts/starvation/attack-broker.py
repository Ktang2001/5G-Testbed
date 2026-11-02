#!/usr/bin/env python3
"""Attack-capable ZMQ broker for the POWDER srsRAN testbed.

Drop-in replacement for scripts/zmq-broker.py that can, on top of the normal
3-UE relay, do two things for security experiments on THIS simulated testbed:

  * Jamming  - inject Gaussian noise into the simulated IQ sample stream
               (uplink, downlink or both), degrading SINR like an RF jammer
               would. The noise exists only inside this GNU Radio flowgraph,
               so it cannot affect any real radio.
  * RACH-flood slots - expose extra attacker UE ports so many rogue srsUE
               instances can hammer random access (see flood-rach.sh).

Everything is off by default, so with no environment set this behaves exactly
like the normal broker. Configure via environment variables:

  JAM_TARGET   none | ul | dl | both   (default none)
  JAM_DB       noise amplitude in dB relative to unit signal (default -3)
  ATTACK_SLOTS integer, extra attacker UE port-pairs to expose (default 0)

Safety: refuses to run unless this is the srsRAN testbed node.
"""

import os
import sys
from gnuradio import gr, blocks, zeromq
from gnuradio import analog   # noise_source_c lives here, not in blocks

SRATE = 23.04e6
GNB_TX, GNB_RX = 2000, 2001
UE_PORTS = [2100, 2200, 2300]
UE_UL_GAINS = [1.0, 0.5, 0.25]
ATTACK_BASE = 2400          # attacker slot i uses rx=2400+2i, tx=2401+2i
ATTACK_GAIN = 1.0           # rogue UEs transmit at full power


def require_testbed():
    """Abort unless the srsRAN testbed is present; this must not run elsewhere."""
    if not (os.path.isdir("/local/repository")
            and os.path.exists("/opt/srsRAN_4G/build/srsue/src/srsue")):
        sys.exit("REFUSING: not the POWDER srsRAN testbed "
                 "(need /local/repository and /opt/srsRAN_4G). "
                 "This broker is for the isolated simulated testbed only.")


class AttackBroker(gr.top_block):
    def __init__(self, jam_target, jam_amp, attack_slots):
        gr.top_block.__init__(self, "attack-broker")
        c = gr.sizeof_gr_complex
        jam_ul = jam_target in ("ul", "both")
        jam_dl = jam_target in ("dl", "both")

        # Downlink: gNB -> every UE (+ attackers), optionally jammed.
        dl_in = zeromq.req_source(c, 1, f"tcp://127.0.0.1:{GNB_TX}", 100, False, -1)
        dl = blocks.throttle(c, SRATE, True)
        self.connect(dl_in, dl)
        if jam_dl:
            dl_add = blocks.add_vcc(1)
            self.connect(dl, (dl_add, 0))
            self.connect(analog.noise_source_c(analog.GR_GAUSSIAN, jam_amp, 0),
                         (dl_add, 1))
            dl_feed = dl_add
        else:
            dl_feed = dl

        # Uplink: sum of all UEs (+ attackers, + noise) -> gNB.
        ul_sum = blocks.add_vcc(1)
        ul_out = zeromq.rep_sink(c, 1, f"tcp://127.0.0.1:{GNB_RX}", 100, False, -1)
        self.connect(ul_sum, ul_out)
        n_in = 0  # next free uplink adder input

        # The three legitimate UEs.
        for port, gain in zip(UE_PORTS, UE_UL_GAINS):
            ue_rx = zeromq.rep_sink(c, 1, f"tcp://127.0.0.1:{port}", 100, False, -1)
            self.connect(dl_feed, ue_rx)
            ue_tx = zeromq.req_source(c, 1, f"tcp://127.0.0.1:{port + 1}", 100, False, -1)
            self.connect(ue_tx, blocks.multiply_const_cc(gain), (ul_sum, n_in))
            n_in += 1

        # Extra attacker slots for RACH flooding.
        for i in range(attack_slots):
            rx_port = ATTACK_BASE + 2 * i
            att_rx = zeromq.rep_sink(c, 1, f"tcp://127.0.0.1:{rx_port}", 100, False, -1)
            self.connect(dl_feed, att_rx)
            att_tx = zeromq.req_source(c, 1, f"tcp://127.0.0.1:{rx_port + 1}", 100, False, -1)
            self.connect(att_tx, blocks.multiply_const_cc(ATTACK_GAIN), (ul_sum, n_in))
            n_in += 1

        # Uplink jamming noise, added last.
        if jam_ul:
            self.connect(analog.noise_source_c(analog.GR_GAUSSIAN, jam_amp, 1),
                         (ul_sum, n_in))
            n_in += 1


if __name__ == "__main__":
    require_testbed()
    jam_target = os.environ.get("JAM_TARGET", "none").lower()
    if jam_target not in ("none", "ul", "dl", "both"):
        sys.exit(f"JAM_TARGET must be none|ul|dl|both, got {jam_target!r}")
    jam_db = float(os.environ.get("JAM_DB", "-3"))
    jam_amp = 10 ** (jam_db / 20.0)
    attack_slots = int(os.environ.get("ATTACK_SLOTS", "0"))

    print(f"attack-broker: jam_target={jam_target} jam_db={jam_db} "
          f"(amp={jam_amp:.3f}) attack_slots={attack_slots}")
    if jam_target != "none":
        print("  JAMMING ACTIVE - simulated noise injected into the ZMQ sample stream.")
    if attack_slots:
        print(f"  RACH-flood slots on ports {ATTACK_BASE}..{ATTACK_BASE + 2*attack_slots - 1}.")

    tb = AttackBroker(jam_target, jam_amp, attack_slots)
    tb.start()
    try:
        input("Broker running. Press Enter to stop.\n")
    except EOFError:
        import signal
        signal.pause()
    tb.stop()
    tb.wait()
