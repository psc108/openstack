# OVN Integration Guide
## Migrating a Running OpenStack Deployment from ML2/OVS or ML2/LXB to ML2/OVN

**Version:** 1.0 | **Date:** June 2026 | **Author:** Infrastructure Team

---

## CONTENTS

1. [Overview](#1-overview)
2. [Architecture Comparison](#2-architecture-comparison)
3. [Prerequisites & Planning](#3-prerequisites--planning)
4. [Phase 1 — Pre-Migration Preparation](#4-phase-1--pre-migration-preparation)
5. [Phase 2 — Controller Node Migration](#5-phase-2--controller-node-migration)
6. [Phase 3 — Database Synchronisation](#6-phase-3--database-synchronisation)
7. [Phase 4 — Compute Node Migration](#7-phase-4--compute-node-migration)
8. [Phase 5 — Validation & Cleanup](#8-phase-5--validation--cleanup)
9. [Rollback Procedure](#9-rollback-procedure)
10. [Post-Migration Configuration](#10-post-migration-configuration)
11. [Known Issues & Caveats](#11-known-issues--caveats)
12. [Reference](#12-reference)

---

## 1. Overview

Open Virtual Network (OVN) is the current recommended Neutron backend for all OpenStack deployments from Antelope (2023.1) onwards. The legacy ML2/OVS (Open vSwitch with separate agents) and ML2/LXB (Linux Bridge) mechanism drivers remain functional but are no longer the upstream default, and LXB support is absent in Epoxy (2024.2) and later.

OVN replaces:

- `neutron-openvswitch-agent` / `neutron-linuxbridge-agent` on compute nodes
- `neutron-l3-agent` (L3 routing is distributed into OVN directly)
- `neutron-dhcp-agent` (replaced by OVN-native DHCP or `ovn-metadata-agent`)
- `neutron-metadata-agent` (replaced by `ovn-metadata-agent` per compute node)

The result is a **distributed, agent-lite architecture** where the OVN Northbound and Southbound databases drive all switching, routing, and security group enforcement via flow programming into OVS on each host — no centralised L3 agent hairpinning east-west traffic.

> **⚠ WARNING — Production impact:** This migration requires a maintenance window. Individual VMs remain reachable throughout a correctly executed migration, but **DHCP lease renewal must propagate before MTU changes take effect** — plan for up to 24 hours if VXLAN or Geneve tunnelling is in use.

---

## 2. Architecture Comparison

### 2.1 ML2/OVS (Legacy)

```
Controller Node
├── neutron-server
├── neutron-l3-agent        ← centralised routing (hairpin east-west)
├── neutron-dhcp-agent      ← per-network DHCP namespace
├── neutron-metadata-agent
└── neutron-openvswitch-agent

Compute Node
├── nova-compute
├── neutron-openvswitch-agent   ← manages br-int, br-tun
└── neutron-metadata-agent (optional)
```

### 2.2 ML2/OVN (Target)

```
Controller Node(s)
├── neutron-server           ← with ml2_ovn driver loaded
├── ovn-northd               ← translates NB→SB database
├── ovsdb-server (NB)        ← Northbound DB
├── ovsdb-server (SB)        ← Southbound DB
└── ovn-controller           ← local OVS flow programmer

Compute Node
├── nova-compute
├── ovn-controller           ← replaces neutron-ovs-agent + l3-agent
└── ovn-metadata-agent       ← per-host metadata proxy
```

**Key differences:**

| Capability | ML2/OVS | ML2/OVN |
|---|---|---|
| East-west routing | Centralised L3 agent | Distributed (each hypervisor) |
| DHCP | Per-network namespace | OVN-native or local agent |
| Security groups | iptables / OVS flows | OVN ACLs (Port Groups) |
| Tunnel protocol | VXLAN / GRE | Geneve (preferred) / VXLAN |
| HA routing | DVR + L3-HA | Native (Chassis-based Gateway) |
| Agents required | ~5 per node | 2 per node (ovn-controller, metadata) |

---

## 3. Prerequisites & Planning

### 3.1 Version Requirements

| OpenStack Release | Minimum OVS | Minimum OVN | Notes |
|---|---|---|---|
| Antelope (2023.1) | 2.17 | 22.09 | OVN default from this release |
| Bobcat (2023.2) | 3.1 | 23.06 | |
| Caracal (2024.1) | 3.2 | 24.03 | |
| Dalmatian (2024.2) | 3.3 | 24.09 | LXB removed |
| Epoxy (2025.1) | 3.4 | 25.03 | |

Verify your installed versions:

```bash
ovs-vsctl --version
ovn-nbctl --version   # if OVN packages already installed
python3 -c "import neutron; print(neutron.__version__)"
```

### 3.2 Tunnel Protocol — MTU Consideration

If your existing deployment uses **VXLAN**, note that migrating to Geneve (OVN default) increases the tunnel header overhead by 8 bytes:

- VXLAN overhead: 50 bytes → effective MTU on 1500-byte physical: **1450**
- Geneve overhead: 58 bytes → effective MTU on 1500-byte physical: **1442**

You must reduce the Neutron network MTU before migration and allow DHCP lease renewal to propagate to all guests (up to 24 hours at default lease time of 86400s).

```bash
# Check existing network MTUs
openstack network list -f json | jq '.[].mtu'

# Check DHCP lease duration
grep dhcp_lease_duration /etc/neutron/neutron.conf
```

### 3.3 Assess Your Current Driver

```bash
grep mechanism_drivers /etc/neutron/plugins/ml2/ml2_conf.ini
```

This guide covers both `openvswitch` → `ovn` and `linuxbridge` → `ovn` paths. Differences are called out per phase.

### 3.4 Snapshot / Backup

Before beginning:

```bash
# Snapshot all tenant VMs (or coordinate with tenants)
for server in $(openstack server list --all-projects -f value -c ID); do
    openstack server image create --name "pre-ovn-migration-${server}" "$server"
done

# Dump the Neutron database
mysqldump --single-transaction neutron > /root/neutron-pre-ovn-$(date +%Y%m%d).sql

# Dump the Nova database
mysqldump --single-transaction nova > /root/nova-pre-ovn-$(date +%Y%m%d).sql

# Record current agent state
openstack network agent list -f json > /root/agents-pre-ovn.json
```

### 3.5 Validate Pre-Migration Connectivity

```bash
# Ping test across tenant networks before touching anything
openstack floating ip list -f value -c "Floating IP Address" | while read fip; do
    ping -c 2 -W 1 "$fip" && echo "OK: $fip" || echo "FAIL: $fip"
done
```

---

## 4. Phase 1 — Pre-Migration Preparation

### 4.1 Install OVN Packages (All Nodes)

**Ubuntu / Debian:**

```bash
apt-get install -y ovn-central ovn-host ovn-common
# ovn-central only needed on controller nodes
```

**RHEL / CentOS Stream / Rocky Linux:**

```bash
dnf install -y ovn ovn-central ovn-host python3-networking-ovn
```

Verify:

```bash
systemctl status ovn-northd
systemctl status ovs-vswitchd
ovs-vsctl show
```

### 4.2 Reduce DHCP Lease Duration (VXLAN/GRE Deployments Only)

This step is required **only** if you are changing tunnel protocol or MTU. It must be done well in advance so all existing leases renew under the shortened duration before you change the MTU.

```bash
# /etc/neutron/neutron.conf
[DEFAULT]
dhcp_lease_duration = 600    # reduce to 10 minutes
```

```bash
systemctl restart neutron-dhcp-agent
```

> **Wait 10 minutes minimum** (one lease cycle) before proceeding so all guests renew and receive the new T1 value. Then reduce network MTUs:

```bash
# Reduce all project networks by 8 bytes
for net_id in $(openstack network list --project-domain default -f value -c ID); do
    current_mtu=$(openstack network show $net_id -f value -c mtu)
    new_mtu=$((current_mtu - 8))
    openstack network set --mtu $new_mtu $net_id
    echo "Set $net_id MTU to $new_mtu"
done
```

> **Wait 24 hours** (or 2× the old lease duration) before continuing. This is non-negotiable for in-flight VXLAN deployments.

### 4.3 Set External IDs on OVS Bridges

OVN needs to know about the physical bridge mappings. Do this on **all nodes**:

```bash
# Adjust br-ex / br-provider to match your deployment
ovs-vsctl set open . external-ids:ovn-bridge-mappings="physnet1:br-ex"

# Set the encapsulation type (use 'geneve' unless forced to 'vxlan')
ovs-vsctl set open . external-ids:ovn-encap-type=geneve

# Set the local IP for tunnel endpoints (use the management/tunnel IP of this node)
ovs-vsctl set open . external-ids:ovn-encap-ip=$(hostname -I | awk '{print $1}')
```

---

## 5. Phase 2 — Controller Node Migration

### 5.1 Configure OVN Databases

On the **primary controller** (or dedicated network node):

```bash
# Start and enable OVN central services
systemctl enable --now ovn-northd
systemctl enable --now ovsdb-server

# Initialise the NB and SB databases if not already done
ovn-nbctl init
ovn-sbctl init

# Confirm databases are listening
ss -tlnp | grep 6641   # NB DB
ss -tlnp | grep 6642   # SB DB
```

For **HA / multi-controller** deployments, configure OVSDB clustering (Raft):

```bash
# On controller-1 (bootstrap)
ovsdb-tool create-cluster /etc/ovn/ovnnb_db.db \
    tcp:CONTROLLER1_IP:6643 "$(hostname)"

ovsdb-tool create-cluster /etc/ovn/ovnsb_db.db \
    tcp:CONTROLLER1_IP:6644 "$(hostname)"

# On controller-2 and controller-3
ovsdb-tool join-cluster /etc/ovn/ovnnb_db.db OVN_Northbound \
    tcp:CONTROLLER2_IP:6643 tcp:CONTROLLER1_IP:6643

ovsdb-tool join-cluster /etc/ovn/ovnsb_db.db OVN_Southbound \
    tcp:CONTROLLER2_IP:6644 tcp:CONTROLLER1_IP:6644
```

### 5.2 Update Neutron Configuration

Edit `/etc/neutron/plugins/ml2/ml2_conf.ini` on all controller nodes:

```ini
[ml2]
# Replace 'openvswitch' or 'linuxbridge' with 'ovn'
mechanism_drivers = ovn
type_drivers = local,flat,vlan,geneve
tenant_network_types = geneve

[ml2_type_geneve]
# Must not overlap with existing VXLAN VNI range
vni_ranges = 1:65536
max_header_size = 38

[ovn]
ovn_nb_connection = tcp:CONTROLLER_IP:6641
ovn_sb_connection = tcp:CONTROLLER_IP:6642
ovn_l3_scheduler = leastloaded
ovn_metadata_enabled = True
enable_distributed_floating_ip = True
```

> For HA clusters, use a comma-separated list for the connection strings:
> `ovn_nb_connection = tcp:CTL1:6641,tcp:CTL2:6641,tcp:CTL3:6641`

Edit `/etc/neutron/neutron.conf`:

```ini
[DEFAULT]
# Remove l3, dhcp, metadata agent entries — OVN handles these
# service_plugins line should no longer list router if using OVN native L3
service_plugins = ovn-router,trunk

# If you were using neutron-metadata-agent, disable it
# OVN uses per-host ovn-metadata-agent instead
```

### 5.3 Stop Legacy Agents (Controller)

```bash
# OVS path
systemctl stop neutron-l3-agent neutron-dhcp-agent neutron-openvswitch-agent
systemctl disable neutron-l3-agent neutron-dhcp-agent neutron-openvswitch-agent

# LXB path
systemctl stop neutron-linuxbridge-agent neutron-l3-agent neutron-dhcp-agent
systemctl disable neutron-linuxbridge-agent neutron-l3-agent neutron-dhcp-agent

# Both paths
systemctl stop neutron-metadata-agent
systemctl disable neutron-metadata-agent
```

### 5.4 Restart neutron-server

```bash
systemctl restart neutron-server
journalctl -u neutron-server -f --no-pager &
# Watch for ML2/OVN driver loading successfully
# Expect: "Registered mechanism drivers: ['ovn']"
```

---

## 6. Phase 3 — Database Synchronisation

This is the critical step that translates the existing Neutron database state into the OVN Northbound database.

### 6.1 Run the OVN DB Sync Utility

```bash
neutron-ovn-db-sync-util \
    --config-file /etc/neutron/neutron.conf \
    --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
    --ovn-neutron_sync_mode migrate \
    --log-file /var/log/neutron/ovn-db-sync.log
```

> `--ovn-neutron_sync_mode migrate` performs a one-time translation and sets up OVN resources. Use `repair` (not `migrate`) for ongoing drift correction post-migration.

This utility:
- Reads all Neutron networks, subnets, ports, routers, security groups, and floating IPs
- Creates equivalent resources in the OVN Northbound database
- Clones existing `br-int` resources to `br-migration` so OVN can find them by UUID
- Reassigns `ovn-controller` from `br-migration` back to `br-int`

Monitor progress:

```bash
tail -f /var/log/neutron/ovn-db-sync.log
```

Verify NB database is populated:

```bash
ovn-nbctl show          # routers, switches, ports
ovn-nbctl list ACL      # security group rules
ovn-sbctl show          # chassis (compute nodes)
```

### 6.2 Verify Port Bindings

```bash
# All ports should be in 'active' or 'down' state; none should be 'error'
openstack port list -f json | jq '.[] | select(.status == "ERROR")'

# Check OVN SB for chassis registration
ovn-sbctl list Chassis
```

---

## 7. Phase 4 — Compute Node Migration

Migrate compute nodes **one at a time** or in small batches. Live migrations are not interrupted by this process, but new bindings will use OVN.

### 7.1 For Each Compute Node

```bash
COMPUTE=compute01.example.com
ssh $COMPUTE
```

#### Stop Legacy Agent

```bash
# OVS path
systemctl stop neutron-openvswitch-agent
systemctl disable neutron-openvswitch-agent

# LXB path
systemctl stop neutron-linuxbridge-agent
systemctl disable neutron-linuxbridge-agent
```

#### Clean Up Legacy Namespaces (OVS Path)

```bash
# Remove qrouter, qdhcp, snat, fip namespaces
for ns in $(ip netns list | grep -E 'qrouter|qdhcp|snat|fip' | awk '{print $1}'); do
    ip netns delete "$ns"
done

# Remove OVS ports that are no longer needed
for port in $(ovs-vsctl list-ports br-int | grep -E '^(qr-|ha-|qg-)'); do
    ovs-vsctl del-port br-int "$port"
done

# Remove tunnel bridge (OVS only)
ovs-vsctl del-br br-tun 2>/dev/null || true
ovs-vsctl del-br br-migration 2>/dev/null || true
```

#### For LXB Deployments — Remove Linux Bridges

```bash
for br in $(brctl show | awk '/^brq/{print $1}'); do
    ip link set "$br" down
    brctl delbr "$br"
done
```

#### Configure and Start ovn-controller

```bash
# Set the OVN SB DB connection
ovs-vsctl set open . external-ids:ovn-remote=tcp:CONTROLLER_IP:6642

# Confirm encap settings applied in Phase 1
ovs-vsctl get open . external-ids

# Enable and start
systemctl enable --now ovn-controller
systemctl enable --now ovn-metadata-agent
```

#### Verify Chassis Registration

```bash
# On the controller
ovn-sbctl show | grep -A5 "Chassis"
# Expect the compute node hostname to appear with its tunnel IP
```

#### Verify VM Connectivity

```bash
# From controller — test floating IPs on VMs running on this compute
openstack server list --host $COMPUTE -f value -c "Name" -c "Networks"
ping -c 3 <floating_ip>
```

### 7.2 Fix Stuck Port Bindings (LXB Migrations)

If VMs on a converted compute node lose connectivity, check port bindings in the Neutron DB:

```bash
mysql -u neutron -p neutron -e \
    "SELECT port_id, vif_type FROM ml2_port_bindings WHERE vif_type='bridge';"
```

If `vif_type` is still `bridge` for ports that should now be `ovs`, update them:

```bash
# Take a backup first — already done in Phase 1
mysql -u neutron -p neutron -e \
    "UPDATE ml2_port_bindings SET vif_type='ovs' WHERE vif_type='bridge' AND host='$COMPUTE';"
```

Then hard-reboot affected VMs:

```bash
openstack server reboot --hard <server_id>
```

---

## 8. Phase 5 — Validation & Cleanup

### 8.1 Network Connectivity Validation

```bash
# All floating IPs should be pingable
openstack floating ip list -f value -c "Floating IP Address" | while read fip; do
    result=$(ping -c 2 -W 2 "$fip" 2>&1)
    if echo "$result" | grep -q "2 received"; then
        echo "✔ OK: $fip"
    else
        echo "✖ FAIL: $fip"
    fi
done

# East-west — requires a test VM pair on the same project network
# From a jump host or tenant VM:
# ping <private_ip_of_peer_vm>
```

### 8.2 Verify OVN State

```bash
# Check OVN logical topology
ovn-nbctl show

# Check southbound chassis and port bindings
ovn-sbctl show

# Check that OVN flows are programmed into OVS on a compute node
ssh compute01 ovs-ofctl dump-flows br-int | head -30
```

### 8.3 Remove Stale Neutron Agents from DB

Legacy agents registered in the Neutron DB should be cleaned up:

```bash
# List dead agents (these are the old OVS/LXB agents)
openstack network agent list --dead

# Remove each dead agent
for agent_id in $(openstack network agent list --dead -f value -c ID); do
    openstack network agent delete "$agent_id"
    echo "Deleted agent $agent_id"
done
```

### 8.4 Restore DHCP Lease Duration

```bash
# /etc/neutron/neutron.conf
[DEFAULT]
dhcp_lease_duration = 86400

systemctl restart neutron-server
```

### 8.5 Run Tempest / Smoke Tests

```bash
# Minimal connectivity smoke test using OpenStack CLI
openstack network create test-ovn-smoke
openstack subnet create --network test-ovn-smoke \
    --subnet-range 192.168.200.0/24 test-ovn-smoke-subnet
openstack router create test-ovn-router
openstack router set --external-gateway public test-ovn-router
openstack router add subnet test-ovn-router test-ovn-smoke-subnet

openstack server create \
    --flavor m1.tiny \
    --image cirros \
    --network test-ovn-smoke \
    --key-name mykey \
    test-ovn-smoke-vm

openstack floating ip create public
openstack server add floating ip test-ovn-smoke-vm <fip>
ping -c 5 <fip>

# Cleanup
openstack server delete test-ovn-smoke-vm
openstack router remove subnet test-ovn-router test-ovn-smoke-subnet
openstack router delete test-ovn-router
openstack network delete test-ovn-smoke
```

---

## 9. Rollback Procedure

Rollback is possible **only before** you delete legacy agents from the database and **only if** you have not removed OVS bridge state. A clean rollback window exists between Phase 2 and Phase 5.

### 9.1 Restore Neutron Configuration

```bash
# Restore ml2_conf.ini to original mechanism driver
# e.g. mechanism_drivers = openvswitch

# Restore neutron.conf service_plugins, agent sections
```

### 9.2 Restore Neutron Database

```bash
mysql -u root -p neutron < /root/neutron-pre-ovn-YYYYMMDD.sql
```

### 9.3 Re-enable Legacy Agents

```bash
# Controller
systemctl enable --now neutron-l3-agent neutron-dhcp-agent \
    neutron-openvswitch-agent neutron-metadata-agent

# Each compute node
ssh compute0N systemctl enable --now neutron-openvswitch-agent
```

### 9.4 Restart neutron-server

```bash
systemctl restart neutron-server
```

> **Note:** After a rollback you must verify all DHCP namespaces have recovered. Namespaces that were deleted during the migration will not automatically recreate — trigger recreation by bouncing the DHCP agent:

```bash
systemctl restart neutron-dhcp-agent
```

---

## 10. Post-Migration Configuration

### 10.1 Ongoing DB Sync (Repair Mode)

After migration, run `neutron-ovn-db-sync-util` periodically in repair mode to correct any drift between the Neutron and OVN databases:

```bash
neutron-ovn-db-sync-util \
    --config-file /etc/neutron/neutron.conf \
    --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
    --ovn-neutron_sync_mode repair
```

Add as a weekly cron or a systemd timer on the controller.

### 10.2 OVN BGP Agent (Optional)

If you wish to advertise tenant networks via BGP to upstream routers, install `ovn-bgp-agent`:

```bash
pip install ovn-bgp-agent
# Configure /etc/ovn-bgp-agent/bgp-agent.conf
# systemctl enable --now ovn-bgp-agent
```

### 10.3 Chassis Gateway Pinning

By default OVN uses `leastloaded` to select gateway chassis for SNAT and floating IPs. To pin specific nodes as gateways:

```bash
# Mark a node as an OVN gateway chassis
ovs-vsctl set open . external-ids:ovn-cms-options=enable-chassis-as-gw

# Verify
ovn-sbctl list Gateway_Chassis
```

### 10.4 Distributed Floating IPs (DVR Equivalent)

OVN supports distributed floating IP handling so SNAT/DNAT occurs on the compute node rather than a dedicated gateway:

```ini
# ml2_conf.ini
[ovn]
enable_distributed_floating_ip = True
```

---

## 11. Known Issues & Caveats

| Issue | Impact | Workaround |
|---|---|---|
| VLAN tenant networks | VLAN-based project networks have had historical bugs in OVN core | Prefer Geneve for project networks; use VLAN only for provider networks |
| Security group default project mismatch | `neutron-ovn-db-sync-util` may fail if a network has no default security group for its project | Create missing default SG before running sync: `openstack security group create default --project <id>` |
| LXB `vif_type=bridge` stuck ports | VMs lose network post-migration | Manually update `ml2_port_bindings` and hard-reboot affected VMs (see Phase 4) |
| MTU mismatch after Geneve migration | Packet fragmentation / TCP performance degradation | Reduce MTU on all project networks by 8 bytes before migration; wait for DHCP lease renewal |
| `ovn-metadata-agent` not starting | VMs cannot reach instance metadata | Ensure `ovn_metadata_enabled = True` in ml2_conf.ini and the agent is running on each compute node |
| HA router removal | Existing HA routers (using VRRP namespaces) are replaced by OVN gateway chassis — the old HA internal networks must be deleted | Handled by `neutron-ovn-db-sync-util` during migration; verify with `openstack network list` post-migration |

---

## 12. Reference

| Resource | URL |
|---|---|
| Neutron OVN Migration Docs | https://docs.openstack.org/neutron/latest/ovn/migration.html |
| OVN Requirements per Release | https://docs.openstack.org/neutron/latest/install/ovs-ovn-requirements.html |
| OpenStack-Ansible OVN Scenario | https://docs.openstack.org/openstack-ansible-os_neutron/latest/app-ovn.html |
| Red Hat OVS→OVN Migration Guide | https://docs.redhat.com/en/documentation/red_hat_openstack_platform/17.1/html/migrating_to_the_ovn_mechanism_driver/ |
| OVN Architecture Overview | https://www.ovn.org/support/dist-docs/ovn-architecture.7.html |

---

*CONFIDENTIAL — Infrastructure Team Internal Documentation*
