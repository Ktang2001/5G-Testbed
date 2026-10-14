"""5G testbed: Open5GS core + srsRAN gNB + srsUE (ZMQ simulated RF).

Instructions:
Wait for the startup scripts to finish (check /local/setup.log on each node).
Then on the 'ran' node, start the gNB and UE:

    sudo /opt/srsRAN_Project/build/apps/gnb/gnb -c /local/repository/config/gnb.yaml
    sudo /opt/srsRAN_4G/build/srsue/src/srsue /local/repository/config/ue.conf

Test with: sudo ip netns exec ue1 ping 10.45.0.1

"""

import geni.portal as portal
import geni.rspec.pg as rspec

pc = portal.Context()
pc.defineParameter("nodetype", "Hardware type", portal.ParameterType.NODETYPE, "d430")
params = pc.bindParameters()
request = pc.makeRequestRSpec()

IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"

lan = request.LAN("lan")

# 5G core node
cn = request.RawPC("cn")
cn.hardware_type = params.nodetype
cn.disk_image = IMAGE
cn_if = cn.addInterface("if0")
cn_if.addAddress(rspec.IPv4Address("10.10.1.1", "255.255.255.0"))
lan.addInterface(cn_if)
cn.addService(rspec.Execute(shell="bash",
    command="sudo bash /local/repository/scripts/setup-cn.sh > /local/setup.log 2>&1"))

# RAN node (gNB + UE)
ran = request.RawPC("ran")
ran.hardware_type = params.nodetype
ran.disk_image = IMAGE
ran_if = ran.addInterface("if0")
ran_if.addAddress(rspec.IPv4Address("10.10.1.2", "255.255.255.0"))
lan.addInterface(ran_if)
ran.addService(rspec.Execute(shell="bash",
    command="sudo bash /local/repository/scripts/setup-ran.sh > /local/setup.log 2>&1"))

pc.printRequestRSpec(request)
