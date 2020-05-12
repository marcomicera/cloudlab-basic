#!/usr/bin/env python2.7
"""
This profile uses a git repository based configuration
"""

import geni.aggregate.cloudlab as cloudlab
import geni.portal as portal
import geni.rspec.pg as pg
import geni.urn as urn

# Portal context is where parameters and the rspec request is defined.
pc = portal.Context()

# The possible set of base disk-images that this cluster can be booted with.
# The second field of every tupule is what is displayed on the cloudlab
# dashboard.
images = [("UBUNTU18-64-STD", "Ubuntu 18.04")]

# The possible set of node-types this cluster can be configured with.
c6420 = ("c6420", "c6420 (CloudLab Clemson, two 16-Core Intel Xeon Gold 6142)")
c6320 = ("c6320", "c6320 (CloudLab Clemson, two 14-Core Intel E5-2683 v3)")
c8220 = ("c8220", "c8220 (CloudLab Clemson, two 10-Core 2.20 GHz Ivy Bridge)")
d430 = ("d430", "d430 (Emulab, 8-Core Intel Xeon E5-2630v3)")
worker_hardware_types = [c6420, c6320, c8220]
switch_hardware_types = worker_hardware_types

# Create a portal context.
pc = portal.Context()

pc.defineParameter("image", "Disk Image",
                   portal.ParameterType.IMAGE, images[0], images,
                   "Specify the base disk image that all the nodes of the cluster " +
                   "should be booted with.")

pc.defineParameter("worker_hardware_type", "Worker Hardware Type",
                   portal.ParameterType.NODETYPE, worker_hardware_types[0], worker_hardware_types)

pc.defineParameter("switch_hardware_type", "Switch Hardware Type",
                   portal.ParameterType.NODETYPE, switch_hardware_types[0], switch_hardware_types)

pc.defineParameter("username", "Username",
                   portal.ParameterType.STRING, "", None,
                   "Username of cloudlab account.")

pc.defineParameter("link_latency", "Link latency",
                   portal.ParameterType.INTEGER, 2, [],
                   "Specify the latency of all connections.")

pc.defineParameter("link_bw", "Links capacity",
                   portal.ParameterType.INTEGER, 800, [],
                   "Specify the link capacity of all connections.")

# Size of partition to allocate for local disk storage.
pc.defineParameter("local_storage_size", "Size of Node Local Storage Partition",
                   portal.ParameterType.STRING, "60GB", [],
                   "Size of local disk partition to allocate for node-local storage.")

params = pc.bindParameters()

# Create a Request object to start building the RSpec.
request = pc.makeRequestRSpec()

# Worker-to-switch link
w2s = request.LAN("link")
w2s.best_effort = True
w2s.vlan_tagging = True
w2s.link_multiplexing = True
w2s.trivial_ok = False
w2s.bandwidth = params.link_bw
w2s.latency = 0.001 * params.link_latency

node_local_storage_dir = "/dev/xvdca"

# Worker node
worker_name = "worker"
worker = request.RawPC(worker_name)
worker.worker_hardware_type = params.worker_hardware_type
worker.disk_image = urn.Image(cloudlab.Utah, "emulab-ops:%s" % params.image)
worker.routable_control_ip = False  # no public IPv4
worker.addService(pg.Execute(shell="sh",
                             command="sudo /local/repository/worker-setup.sh %s %s" %
                                     (node_local_storage_dir, params.username)))
w2s_worker_iface = worker.addInterface("w2s_worker_iface")
w2s.addInterface(w2s_worker_iface)

# Switch
switch_name = "switch"
switch = request.RawPC(switch_name)
switch.switch_hardware_type = params.switch_hardware_type
switch.disk_image = urn.Image(cloudlab.Utah, "emulab-ops:%s" % params.image)
switch.routable_control_ip = False  # no public IPv4
switch.addService(pg.Execute(shell="sh",
                             command="sudo /local/repository/switch-setup.sh %s" % params.username))
w2s_switch_iface = switch.addInterface("w2s_switch_iface")
w2s.addInterface(w2s_switch_iface)

# Print the RSpec to the enclosing page.
pc.printRequestRSpec(request)
