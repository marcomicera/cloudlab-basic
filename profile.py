#!/usr/bin/env python2.7
"""
This profile uses a git repository based configuration
"""

import re
import geni.aggregate.cloudlab as cloudlab
import geni.portal as portal
import geni.rspec.emulab as emulab
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
c8220 = ("c8220", "c8220 (CloudLab Clemson, two 10-Core 2.20 GHz Ivy Bridge)")
d430 = ("d430", "d430 (Emulab, 8-Core Intel Xeon E5-2630v3)")
worker_hardware_types = [c6420, c8220]

# Create a portal context.
pc = portal.Context()

pc.defineParameter("image", "Disk Image",
                   portal.ParameterType.IMAGE, images[0], images,
                   "Specify the base disk image that all the nodes of the cluster " +
                   "should be booted with.")

pc.defineParameter("hardware_type", "Hardware Type",
                   portal.ParameterType.NODETYPE, worker_hardware_types[0], worker_hardware_types)

pc.defineParameter("username", "Username",
                   portal.ParameterType.STRING, "", None,
                   "Username of cloudlab account.")

# Default the cluster size to 5 nodes (minimum requires to support a
# replication factor of 3 and an independent coordinator).
pc.defineParameter("num_worker", "Cluster Size (# workers)",
                   portal.ParameterType.INTEGER, 32, [],
                   "Specify the number of worker servers. Note that the total " +
                   "number of servers in the experiment will be this number + #tor-switches/2 + 2 (one " +
                   "additional server which acts as a jumphost and one additional " +
                   "server which acts as experiment controller). To check " +
                   "availability of nodes, visit " +
                   "\"https://www.cloudlab.us/cluster-graphs.php\"")

#
pc.defineParameter("num_tor", "Cluster Size (# tor)",
                   portal.ParameterType.INTEGER, 4, [],
                   "Specify the number of tor switches. Note that the total " +
                   "number of tor swithces must be a multiple of two. " +
                   "Worker id % #tor gives the tor of a worker")


pc.defineParameter("latency_tor", "Latency of TOR links (in ms)",
                   portal.ParameterType.INTEGER, 3, [],
                   "Specify the latency of all TOR connections. ")

pc.defineParameter("latency_core", "Latency of CORE links (in ms)",
                   portal.ParameterType.INTEGER, 2, [],
                   "Specify the latency of all CORE connections. ")


pc.defineParameter("bw_tor", "Link capacity of TOR links",
                   portal.ParameterType.INTEGER, 400, [],
                   "Specify the link capacity of all TOR connections. ")


pc.defineParameter("bw_core", "Link capacity of CORE links",
                   portal.ParameterType.INTEGER, 800, [],
                   "Specify the link capacity of all CORE connections. ")

# Size of partition to allocate for local disk storage.
pc.defineParameter("local_storage_size", "Size of Node Local Storage Partition",
                   portal.ParameterType.STRING, "60GB", [],
                   "Size of local disk partition to allocate for node-local storage.")

# Size of partition to allocate for NFS shared home directories.
pc.defineParameter("nfs_storage_size", "Size of NFS Shared Storage",
                   portal.ParameterType.STRING, "60GB", [],
                   "Size of disk partition to allocate on NFS server.")

# Datasets to connect to the cluster (shared via NFS).
pc.defineParameter("dataset_urns", "datasets",
                   portal.ParameterType.STRING, "", None,
                   "Space separated list of datasets to mount. All datasets are " +
                   "first mounted on the NFS server at /remote, and then mounted via " +
                   "NFS on all other nodes at /datasets/dataset-name")

params = pc.bindParameters()

if params.num_tor < 2 or (params.num_tor % 2) != 0:
    portal.context.reportError(portal.ParameterError(
        "You must specify the number of tor switches to be a multiple of two (and >=2)."))

# Create a Request object to start building the RSpec.
request = pc.makeRequestRSpec()

# Create a dedicated network for the experiment
tors = []
for i in range(params.num_tor):
    testlan = request.LAN("tor%02d" % (i+1))
    testlan.best_effort = True
    testlan.vlan_tagging = True
    testlan.link_multiplexing = True
    testlan.trivial_ok = False
    testlan.bandwidth = params.bw_tor
    testlan.latency = 0.001 * params.latency_tor
    tors.append(testlan)

core = request.LAN("core")
core.best_effort = True
core.vlan_tagging = True
core.link_multiplexing = True
core.trivial_ok = False
core.bandwidth = params.bw_core
core.latency = 0.001 * params.latency_core

# Create a special network for connecting datasets to the nfs server.
dslan = request.LAN("dslan")
dslan.best_effort = True
dslan.vlan_tagging = True
dslan.link_multiplexing = True


# Create array of the requested datasets
dataset_urns = []
if (params.dataset_urns != ""):
    dataset_urns = params.dataset_urns.split(" ")

nfs_shared_home_export_dir = "/local/nfs"
nfs_datasets_export_dir = "/remote"

# Add datasets to the dataset-lan
for i in range(len(dataset_urns)):
    dataset_urn = dataset_urns[i]
    dataset_name = dataset_urn[dataset_urn.rfind("+") + 1:]
    rbs = request.RemoteBlockstore(
        "dataset%02d" % (i + 1),
        nfs_datasets_export_dir + "/" + dataset_name,
        "if1")
    rbs.dataset = dataset_urn
    dslan.addInterface(rbs.interface)

# Setup node names
HOSTNAME_JUMPHOST = "jumphost"
HOSTNAME_EXP_CONTROLLER = "expctrl"

node_local_storage_dir = "/dev/xvdca"

hostnames = []
for i in range(params.num_worker):
    hostnames.append("worker%02d" % (i + 1))
hostnames += [HOSTNAME_JUMPHOST, HOSTNAME_EXP_CONTROLLER]

aggnames = []
for i in range(int(params.num_tor)/2):
    aggnames.append("agg%02d" % (i + 1))

# Setup the cluster one node at a time.
for idx, host in enumerate(hostnames):
    node = request.RawPC(host)
    node.hardware_type = params.hardware_type if host.startswith('worker') else c8220[0]
    node.disk_image = urn.Image(cloudlab.Utah, "emulab-ops:%s" % params.image)

    if (host == HOSTNAME_JUMPHOST):
        # public ipv4
        node.routable_control_ip = True

        nfs_bs = node.Blockstore(host + "_nfs_bs", nfs_shared_home_export_dir)
        nfs_bs.size = params.nfs_storage_size

        dslan.addInterface(node.addInterface("if2"))
    else:
        # NO public ipv4
        node.routable_control_ip = False

    node.addService(pg.Execute(shell="sh",
                               command="sudo /local/repository/system-setup.sh %s %s %s %s %s %s" %
                               (node_local_storage_dir, params.username,
                                params.num_worker, len(aggnames), nfs_shared_home_export_dir, nfs_datasets_export_dir)))

    # All nodes in the cluster connect to clan.
    n_iface = node.addInterface("exp_iface")
    if (host not in [HOSTNAME_JUMPHOST, HOSTNAME_EXP_CONTROLLER]):
        tors[idx % params.num_tor].addInterface(n_iface)
    else:
        core.addInterface(n_iface)

    if (host != HOSTNAME_JUMPHOST):
        local_storage_bs = node.Blockstore(host + "_local_storage_bs",
                                           node_local_storage_dir)
        local_storage_bs.size = params.local_storage_size


for idx, host in enumerate(aggnames):
    node = request.RawPC(host)
    node.routable_control_ip = False
    node.hardware_type = c8220[0]
    node.disk_image = urn.Image(cloudlab.Utah, "emulab-ops:%s" % params.image)

    node.addService(pg.Execute(shell="sh",
                               command="sudo /local/repository/agg-setup.sh %s" %
                               (params.username)))

    # All nodes in the cluster connect to clan.
    n_iface_l = node.addInterface("c-left")
    n_iface_r = node.addInterface("c-right")
    n_iface_c = node.addInterface("c-core")

    tors[idx*2].addInterface(n_iface_l)
    tors[idx*2+1].addInterface(n_iface_r)
    core.addInterface(n_iface_c)


# Print the RSpec to the enclosing page.
pc.printRequestRSpec(request)
