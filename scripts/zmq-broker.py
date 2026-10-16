#!/usr/bin/env python3
"""ZMQ broker: connects one srsRAN gNB to three srsUEs (simulated radio)."""

from gnuradio import gr, blocks, zeromq

SRATE = 23.04e6
GNB_TX, GNB_RX = 2000, 2001
UE_PORTS = [2100, 2200, 2300] 


class Broker(gr.top_block):
    def __init__(self):
        gr.top_block.__init__(self, "multi-ue-broker")
        c = gr.sizeof_gr_complex

        # Downlink: gNB -> every UE
        dl_in = zeromq.req_source(c, 1, f"tcp://127.0.0.1:{GNB_TX}", 100, False, -1)
        dl = blocks.throttle(c, SRATE, True)
        self.connect(dl_in, dl)

        # Uplink: sum of all UEs -> gNB
        ul_sum = blocks.add_vcc(1)
        ul_out = zeromq.rep_sink(c, 1, f"tcp://127.0.0.1:{GNB_RX}", 100, False, -1)
        self.connect(ul_sum, ul_out)

        for i, port in enumerate(UE_PORTS):
            ue_rx = zeromq.rep_sink(c, 1, f"tcp://127.0.0.1:{port}", 100, False, -1)
            self.connect(dl, ue_rx)
            ue_tx = zeromq.req_source(c, 1, f"tcp://127.0.0.1:{port + 1}", 100, False, -1)
            self.connect(ue_tx, (ul_sum, i))


if __name__ == "__main__":
    tb = Broker()
    tb.start()
    input("Broker running. Press Enter to stop.\n")
    tb.stop()
    tb.wait()
