---
Subject: OpenStack Installation and Operations Guide
Prepared By: scottp
Author Title: Engineer
Work Stream: OpenStack Lab
Version: 1.0
Date: 2025-01-27
Status: Complete
---

# OpenStack Installation and Operations Guide

## Introduction

### Purpose

This guide provides complete installation and operations instructions for OpenStack Caracal (2024.1) on a single Ubuntu 24.04 laptop. The deployment is air-gap capable and includes detailed operations procedures using both the Horizon web dashboard and OpenStack CLI.

### Audience

Engineers learning OpenStack architecture and operations, system administrators deploying OpenStack, and users who need to manage instances, networks, volumes, and other cloud resources.

### Scope

- Single-node deployment (all services on one machine)
- Air-gap installation capability
- Complete operations procedures
- Troubleshooting and maintenance guidance
- LVM-backed block storage with thin provisioning
- VXLAN networking without route hijacking
- KVM/QEMU virtualisation

## Preparedness

### Prerequisites

- [ ] Ubuntu 24.04 LTS (Noble Numbat)
- [ ] 32 GB RAM minimum
- [ ] 4 vCPUs minimum
- [ ] Root filesystem with 50+ GB free space
- [ ] Internet access (for initial download phase only)
- [ ] Root or sudo access

### Pre-Work

- [ ] Run `sudo bash scripts/00-download.sh` while connected to internet
- [ ] Verify download completed: `ls /opt/openstack-airgap/debs/ | wc -l`
- [ ] Ensure system meets minimum requirements

## Installation Overview

### Design Principles

- Single-node: all controller and compute roles on one machine
- Idempotent: every script can be re-run safely (nuke-first approach)
- Air-gap ready: download once, install repeatedly without internet
- Educational: extensive comments explain every configuration choice
- Minimal resource usage: no HA components, conservative memory allocation
- Production quality: all scripts handle errors and edge cases

### Implementation Plan

#### Phase 1: Download (requires internet)
```bash
sudo bash scripts/00-download.sh
```
Downloads all .deb packages, builds a local apt repository, and fetches the CirrOS test image.

#### Phase 2: Installation (works offline)
```bash
# Step 1: Base infrastructure
sudo bash scripts/01-base.sh     # MariaDB, RabbitMQ, Memcached

# Step 2: Core services
sudo bash scripts/02-keystone.sh  # Identity service
sudo bash scripts/03-glance.sh    # Image service
sudo bash scripts/04-placement.sh # Resource tracking

# Step 3: Compute and networking
sudo bash scripts/05-nova.sh      # Compute service
sudo bash scripts/06-neutron.sh   # Networking service

# Step 4: Storage and interfaces
sudo bash scripts/07-cinder.sh    # Block storage
sudo bash scripts/08-horizon.sh   # Web dashboard
sudo bash scripts/09-heat.sh      # Orchestration
sudo bash scripts/11-octavia.sh   # Load balancing

# Step 5: Post-installation
sudo bash scripts/10-post-install.sh # Networks, flavors, verification
```

#### Uninstall Everything
```bash
sudo bash scripts/99-uninstall.sh
```

### Solution Components

| Component | Description | Version | Status |
|---|---|---|---|
| MariaDB | Relational database for all OpenStack services | 10.11+ | ✅ Ready |
| RabbitMQ | AMQP message broker for inter-service communication | 3.12+ | ✅ Ready |
| Memcached | In-memory cache for Keystone token validation | 1.6+ | ✅ Ready |
| Keystone | Identity and authentication service | Caracal (2024.1) | ✅ Ready |
| Glance | Image management service | Caracal (2024.1) | ✅ Ready |
| Placement | Resource inventory and allocation tracking | Caracal (2024.1) | ✅ Ready |
| Nova | Compute service (VM lifecycle management) | Caracal (2024.1) | ✅ Ready |
| Neutron | Networking service (VXLAN, no route hijacking) | Caracal (2024.1) | ✅ Ready |
| Cinder | Block storage service (thin LVM backend) | Caracal (2024.1) | ✅ Ready |
| Horizon | Web dashboard (Django + Apache) | Caracal (2024.1) | ✅ Ready |
| Heat | Orchestration service (infrastructure-as-code) | Caracal (2024.1) | ✅ Ready |
| Octavia | Load Balancing service (HAProxy amphorae) | Caracal (2024.1) | ✅ Ready |
| KVM/QEMU | Hypervisor for VM execution | System packages | ✅ Ready |

## OpenStack Services Overview

### Core Services

| Service | Component | Purpose | Key Functions |
|---------|-----------|---------|---------------|
| **Identity** | Keystone | Authentication & Authorization | User/project management, token issuance, service catalog, policy enforcement |
| **Compute** | Nova | Virtual Machine Management | Instance lifecycle, hypervisor management, scheduling, flavors |
| **Networking** | Neutron | Software-Defined Networking | Virtual networks, subnets, routers, security groups, floating IPs |
| **Image** | Glance | VM Image Repository | Image storage, format conversion, metadata management |
| **Block Storage** | Cinder | Persistent Volume Management | Volume creation, snapshots, attachment to instances |
| **Object Storage** | Swift | Scalable Object Storage | File/object storage with REST API (not deployed in this lab) |
| **Orchestration** | Heat | Infrastructure as Code | Template-based resource deployment, stack management |
| **Dashboard** | Horizon | Web Interface | Graphical management interface for all services |
| **Placement** | Placement | Resource Tracking | Resource provider inventory, allocation tracking |
| **Telemetry** | Ceilometer | Monitoring & Metering | Resource usage collection, billing data (not deployed) |

### Service Interactions

**Instance Launch Flow:**
1. **Keystone** — Authenticates user and validates permissions
2. **Nova** — Receives launch request, validates flavor/image
3. **Glance** — Provides VM image to compute node
4. **Neutron** — Creates virtual network port for instance
5. **Nova Scheduler** — Selects suitable compute node
6. **Nova Compute** — Creates VM on selected hypervisor
7. **Cinder** (if volumes) — Attaches persistent storage

**Boot-from-Volume Flow:**
1. **Cinder** — Creates volume from Glance image
2. **Cinder** — Exports volume via iSCSI target
3. **Nova** — Attaches volume to compute node via iSCSI
4. **Nova** — Launches VM with volume as root disk

### Component Architecture

**Nova (Compute):**
- `nova-api` — REST API endpoint
- `nova-scheduler` — Decides which compute node gets new instances
- `nova-compute` — Manages VMs on hypervisor (libvirt/KVM)
- `nova-conductor` — Database access layer, coordinates operations

**Neutron (Networking):**
- `neutron-server` — API and orchestration
- `neutron-linuxbridge-agent` — Implements virtual networking (alternative: OVS)
- `neutron-dhcp-agent` — DHCP services for tenant networks
- `neutron-metadata-agent` — Instance metadata proxy
- `neutron-l3-agent` — Router and floating IP services

**Cinder (Block Storage):**
- `cinder-api` — REST API for volume operations
- `cinder-scheduler` — Selects storage backend
- `cinder-volume` — Manages storage backend (LVM, Ceph, etc.)
- `cinder-backup` — Volume backup services (not deployed)

**Octavia (Load Balancing):**
- `octavia-api` — REST API for load balancer management
- `octavia-health-manager` — Monitors amphora health via UDP heartbeat
- `octavia-housekeeping` — Cleanup and maintenance tasks
- `octavia-worker` — Provisions and manages amphora instances
- `amphora` — HAProxy-based load balancer VMs

**Database & Messaging:**
- **MariaDB** — Stores service state and configuration
- **RabbitMQ** — Message queue for service communication
- **Memcached** — Token caching for performance

## Boot-from-Volume Instance Sequence

### Overview

Understanding the boot-from-volume process helps troubleshoot when instances fail to launch. Here's the complete sequence:

### 1. Volume Creation & Preparation
- **Cinder** creates LVM volume from Glance image
- `qemu-img convert` converts image format (qcow2 → raw) on LVM backend
- Volume marked as "bootable" with proper metadata
- Image contents written to `/dev/cinder-volumes/volume-<uuid>`

### 2. Volume Export (iSCSI Target Creation)
- **Cinder** creates iSCSI target using LIO (`lioadm`) or TGT (`tgtadm`)
- Target gets network portal binding (IP address and port)
- Volume exported as LUN 0 on iSCSI target
- Target IQN: `iqn.2010-10.org.openstack:volume-<uuid>`

### 3. Nova Scheduling & Resource Allocation
- **Nova API** validates request (flavor exists, quotas available)
- **Nova Scheduler** finds compute node with sufficient resources
- **Placement** service tracks resource allocation
- Instance UUID assigned, database records created

### 4. Network Preparation
- **Neutron** creates virtual port for instance
- **LinuxBridge/OVS agent** configures virtual networking
- **DHCP agent** reserves IP address from subnet pool
- Security group rules applied to port

### 5. Volume Attachment (iSCSI Connection)
- **Nova Compute** initiates volume attachment
- **iSCSI initiator** discovers target: `iscsiadm -m discovery -t st -p 127.0.0.1:3260`
- **iSCSI session** established to target
- Block device appears on compute node (e.g., `/dev/disk/by-path/ip-127.0.0.1:3260-iscsi-iqn...`)
- Device mapped for libvirt use

### 6. Libvirt VM Definition & QEMU Launch
- **Nova Compute** generates libvirt XML domain definition
- **Libvirt** creates VM with iSCSI volume as root disk (`/dev/vda`)
- **QEMU** hypervisor process starts
- Virtual network interfaces attached to Linux bridges
- VNC console becomes available

### 7. Guest Operating System Boot
- **VM BIOS/UEFI** initializes and finds boot device
- **Bootloader** (GRUB/syslinux) loads from volume
- **Kernel** starts with root filesystem on persistent volume
- **cloud-init** configures SSH keys, hostname, networking
- Instance reaches ACTIVE state, services start

### Troubleshooting Boot-from-Volume Issues

**Volume Creation Failures:**
```bash
# Check Cinder services
openstack volume service list

# Check volume backend
sudo vgs cinder-volumes
sudo lvs cinder-volumes

# Review logs
sudo tail -f /var/log/cinder/cinder-volume.log
```

**iSCSI Target Issues:**
```bash
# Check iSCSI targets (LIO)
sudo targetcli ls

# Check iSCSI targets (TGT)
sudo tgtadm --lld iscsi --op show --mode target

# Test connectivity
sudo iscsiadm -m discovery -t st -p 127.0.0.1:3260
```

**Instance Launch Problems:**
```bash
# Check Nova services
openstack compute service list

# Check instance events
openstack server event list <instance-id>

# Review compute logs
sudo tail -f /var/log/nova/nova-compute.log
```

**Boot Process Issues:**
```bash
# Access console to see boot messages
openstack console url show <instance-id>

# Check console log
openstack console log show <instance-id>

# Verify volume attachment
openstack server show <instance-id> -c volumes_attached
```

### Access Methods

**Horizon Dashboard:**
- URL: http://127.0.0.1/horizon/
- Admin: `admin` / `changeit` (Domain: Default)
- Demo: `demo` / `changeit` (Domain: Default)

**CLI Access:**
```bash
# Admin operations
sudo bash -c 'source /root/admin-openrc.sh && openstack <command>'

# Demo user operations  
sudo bash -c 'source /root/demo-openrc.sh && openstack <command>'
```

## Instance Management

### Launch an Instance

**Via Horizon:**
1. Login as demo user
2. Navigate: **Project → Compute → Instances**
3. Click **Launch Instance**
4. **Details tab:** Name = `my-test-vm`, Count = 1
5. **Source tab:** Select Boot Source = Image, Select `cirros`
6. **Flavor tab:** Select `m1.tiny`
7. **Networks tab:** Select `selfservice`
8. **Key Pair tab:** Select `mykey`
9. **Security Groups tab:** Ensure `default` is selected
10. Click **Launch Instance**

**Via CLI:**
```bash
# List available resources first
openstack image list
openstack flavor list
openstack network list
openstack keypair list

# Launch instance
openstack server create \
  --flavor m1.tiny \
  --image cirros \
  --network selfservice \
  --key-name mykey \
  --security-group default \
  my-test-vm
```

### Monitor Instance Status

**Via Horizon:**
1. Navigate: **Project → Compute → Instances**
2. View Status column (BUILD → ACTIVE)
3. Click instance name for detailed view

**Via CLI:**
```bash
# List all instances
openstack server list

# Show specific instance details
openstack server show my-test-vm

# Monitor until ACTIVE
watch -n 2 'openstack server list'
```

### Access Instance Console

**Via Horizon:**
1. Navigate: **Project → Compute → Instances**
2. Click dropdown arrow next to instance
3. Select **Console**
4. Click **Click here to show only console**

**Via CLI:**
```bash
# Get VNC console URL
openstack console url show my-test-vm

# For direct access, copy URL to browser
```

### Reboot/Stop/Start Instance

**Via Horizon:**
1. Navigate: **Project → Compute → Instances**
2. Select instance checkbox
3. Use **Actions** dropdown or click dropdown next to instance:
   - **Soft Reboot** (graceful)
   - **Hard Reboot** (forced)
   - **Shut Off** (stop)
   - **Start** (if stopped)

**Via CLI:**
```bash
# Soft reboot (SIGTERM then SIGKILL)
openstack server reboot --soft my-test-vm

# Hard reboot (immediate)
openstack server reboot --hard my-test-vm

# Stop instance
openstack server stop my-test-vm

# Start stopped instance
openstack server start my-test-vm

# Check power state
openstack server show my-test-vm -c power_state
```

### Delete Instance

**Via Horizon:**
1. Navigate: **Project → Compute → Instances**
2. Select instance checkbox
3. Click **Delete Instances**
4. Confirm deletion

**Via CLI:**
```bash
# Delete single instance
openstack server delete my-test-vm

# Delete multiple instances
openstack server delete vm1 vm2 vm3

# Force delete if stuck
openstack server delete --force my-test-vm
```

## Networking

### Create Private Network

**Via Horizon:**
1. Navigate: **Project → Network → Networks**
2. Click **Create Network**
3. **Network tab:** Name = `my-private-net`
4. **Subnet tab:** 
   - Subnet Name = `my-private-subnet`
   - Network Address = `192.168.100.0/24`
   - Gateway IP = `192.168.100.1`
5. **Subnet Details tab:** 
   - Enable DHCP = Yes
   - DNS Name Servers = `8.8.8.8`
6. Click **Create**

**Via CLI:**
```bash
# Create network
openstack network create my-private-net

# Create subnet
openstack subnet create \
  --network my-private-net \
  --subnet-range 192.168.100.0/24 \
  --gateway 192.168.100.1 \
  --dns-nameserver 8.8.8.8 \
  --dhcp \
  my-private-subnet

# List networks
openstack network list
```

### Create and Attach Router

**Via Horizon:**
1. Navigate: **Project → Network → Routers**
2. Click **Create Router**
3. Name = `my-router`, External Network = `provider`
4. Click **Create Router**
5. Click router name to open details
6. **Interfaces tab** → **Add Interface**
7. Subnet = `my-private-subnet`
8. Click **Submit**

**Via CLI:**
```bash
# Create router with external gateway
openstack router create my-router
openstack router set --external-gateway provider my-router

# Add internal interface
openstack router add subnet my-router my-private-subnet

# List routers
openstack router list
openstack router show my-router
```

### Floating IPs

**Via Horizon:**
1. Navigate: **Project → Network → Floating IPs**
2. Click **Allocate IP To Project**
3. Pool = `provider`
4. Click **Allocate IP**
5. Click **Associate** next to the new IP
6. Port = Select your instance
7. Click **Associate**

**Via CLI:**
```bash
# Create floating IP
openstack floating ip create provider

# List floating IPs
openstack floating ip list

# Associate with instance
openstack server add floating ip my-test-vm <FLOATING_IP>

# Dissociate from instance
openstack server remove floating ip my-test-vm <FLOATING_IP>

# Delete floating IP
openstack floating ip delete <FLOATING_IP>
```

### Security Groups

**Via Horizon:**
1. Navigate: **Project → Network → Security Groups**
2. Click **Create Security Group**
3. Name = `web-servers`, Description = `HTTP and HTTPS access`
4. Click **Create Security Group**
5. Click **Manage Rules** next to the new group
6. Click **Add Rule**
7. Rule = `HTTP` (Port 80), Remote = `CIDR`, CIDR = `0.0.0.0/0`
8. **Add Rule** again for HTTPS (Port 443)

**Via CLI:**
```bash
# Create security group
openstack security group create web-servers --description "HTTP and HTTPS access"

# Add rules
openstack security group rule create --protocol tcp --dst-port 80 --remote-ip 0.0.0.0/0 web-servers
openstack security group rule create --protocol tcp --dst-port 443 --remote-ip 0.0.0.0/0 web-servers
openstack security group rule create --protocol icmp web-servers

# List security groups and rules
openstack security group list
openstack security group show web-servers

# Assign to instance (at launch or after)
openstack server create --security-group web-servers ...
openstack server add security group my-test-vm web-servers
```

## Volume (Block Storage) Management

### ✅ Current Status: FULLY OPERATIONAL — ALL ISSUES RESOLVED

**Working Configuration:**
- **Backend**: File-based LVM with thin provisioning
- **Volume Group**: `cinder-volumes-file` 
- **LVM Type**: `thin` (with thin pool: `cinder-volumes-file-pool`)
- **Target Helper**: `tgtadm` 
- **Networking**: VXLAN-based provider networks (no route hijacking)
- **Status**: ALL operations functional including boot-from-volume and instance creation

**Complete Functionality:**
- ✅ Basic volume creation/deletion
- ✅ Image-to-volume conversion  
- ✅ Boot-from-volume instances
- ✅ Volume attachment/detachment
- ✅ Volume snapshots
- ✅ iSCSI target management
- ✅ Instance creation from CLI and Horizon
- ✅ Network allocation without IP conflicts
- ✅ Stable host networking (no route hijacking)

**Key Success Factors**: 
- `lvm_type = thin` with proper thin pool configuration
- VXLAN provider networks without physical interface mapping
- Integrated route hijacking protection in installation scripts

**Verification Commands:**
```bash
# Check service health
sudo cinder-manage service list
# Should show ":-)" status for cinder-volume

# Test basic volume
openstack volume create --size 2 test-volume
sleep 8
openstack volume show test-volume -c status
# Should show "available"

# Test boot volume creation
openstack volume create --size 5 --image cirros boot-vol
sleep 10
openstack volume show boot-vol -c status -c bootable
# Should show: status="available", bootable="true"

# Test boot-from-volume instance
openstack server create --flavor m1.tiny --volume boot-vol --network selfservice vm1
sleep 15
openstack server show vm1 -c status
# Should show "ACTIVE" with "N/A (booted from volume)"
```

### Create Volume

**Via Horizon:**
1. Navigate: **Project → Volumes → Volumes**
2. Click **Create Volume**
3. **Volume Name** = `my-data-volume`
4. **Size (GiB)** = `10`
5. **Volume Source** = `No source, empty volume`
6. **Type** = `file`
7. Click **Create Volume**

**Via CLI:**
```bash
# Create empty volume
openstack volume create --size 10 --type file my-data-volume

# Create volume from image (for boot-from-volume)
openstack volume create --size 10 --image cirros --type file my-boot-volume

# List volumes
openstack volume list

# Show volume details
openstack volume show my-data-volume
```

### Boot-from-Volume Benefits

**Why use boot-from-volume?**
- ✅ **Persistent root storage** — survives instance deletion
- ✅ **Larger root disks** — not limited by flavor disk size
- ✅ **Snapshots** — backup your entire system state
- ✅ **Live migration** — move instances between compute nodes
- ✅ **Performance** — dedicated storage bandwidth
- ✅ **Flexibility** — resize, clone, backup independently

**Boot Process Difference:**
```
Traditional Instance:
Nova → Downloads image → Creates ephemeral disk → Boots VM
(Root disk lost when instance deleted)

Boot-from-Volume:
Cinder → Creates volume from image → Exports via iSCSI → Nova attaches → Boots VM
(Root disk persists as Cinder volume)
```

### Attach/Detach Volume

**Via Horizon:**
1. Navigate: **Project → Volumes → Volumes**
2. Click dropdown next to volume
3. Select **Manage Attachments**
4. **Attach To Instance** = Select instance
5. Click **Attach Volume**

To detach:
1. Click **Manage Attachments** again
2. Click **Detach Volume**

**Via CLI:**
```bash
# Attach volume to instance
openstack server add volume my-test-vm my-data-volume

# List attachments
openstack volume list

# Detach volume
openstack server remove volume my-test-vm my-data-volume

# Show where volume is attached
openstack volume show my-data-volume -c attachments
```

### Volume Snapshots

**Via Horizon:**
1. Navigate: **Project → Volumes → Volumes**
2. Click dropdown next to volume
3. Select **Create Snapshot**
4. **Snapshot Name** = `my-volume-backup`
5. Click **Create Volume Snapshot**

**Via CLI:**
```bash
# Create snapshot
openstack volume snapshot create --volume my-data-volume my-volume-backup

# List snapshots
openstack volume snapshot list

# Create volume from snapshot
openstack volume create --snapshot my-volume-backup --size 10 restored-volume

# Delete snapshot
openstack volume snapshot delete my-volume-backup
```

### Create Bootable Volume and Launch Boot-from-Volume Instance

**Via Horizon:**
1. Navigate: **Project → Volumes → Volumes**
2. Click **Create Volume**
3. **Volume Name** = `my-boot-volume`
4. **Size (GiB)** = `10`
5. **Volume Source** = `Image`
6. **Use image as a source** = Select `cirros`
7. **Type** = `file`
8. Click **Create Volume**
9. Wait for status = `Available` and `Bootable` = `Yes`
10. Navigate: **Project → Compute → Instances**
11. Click **Launch Instance**
12. **Source tab**: Select Boot Source = `Volume`, choose your boot volume
13. Continue with flavor, networks, etc.

**Via CLI:**
```bash
# Create bootable volume from image
openstack volume create --size 10 --image cirros --type file my-boot-volume

# Wait for creation and verify
watch -n 2 'openstack volume show my-boot-volume -c status -c bootable'
# Wait for: status=available, bootable=true

# Launch boot-from-volume instance
openstack server create \
  --flavor m1.tiny \
  --volume my-boot-volume \
  --network selfservice \
  --key-name mykey \
  boot-vm

# Verify the instance
openstack server show boot-vm -c status -c image
# Should show: status=ACTIVE, image="N/A (booted from volume)"

# Check volume attachment
openstack volume show my-boot-volume -c status -c attachments
# Should show: status=in-use with device=/dev/vda
```

## Image Management

### Upload Image

**Via Horizon:**
1. Navigate: **Project → Compute → Images**
2. Click **Create Image**
3. **Image Name** = `ubuntu-20.04`
4. **Image Source** = `Image File`
5. **Browse** and select your image file
6. **Format** = `QCOW2`
7. **Architecture** = `x86_64`
8. **Minimum Disk (GB)** = `20`
9. **Minimum RAM (MB)** = `1024`
10. **Public** = Yes (if admin)
11. Click **Create Image**

**Via CLI:**
```bash
# Upload image file
openstack image create \
  --container-format bare \
  --disk-format qcow2 \
  --public \
  --property os_distro=ubuntu \
  --property os_version=20.04 \
  --file ubuntu-20.04.qcow2 \
  ubuntu-20.04

# List images
openstack image list

# Set image properties
openstack image set --min-disk 20 --min-ram 1024 ubuntu-20.04

# Delete image
openstack image delete ubuntu-20.04
```

### Create Instance from Volume

**Via Horizon:**
1. Navigate: **Project → Compute → Instances**
2. Click **Launch Instance**
3. **Source tab:**
   - Select Boot Source = `Instance Snapshot` or `Volume`
   - Choose your volume/snapshot
   - **Delete Volume on Instance Delete** = No (usually)
4. Continue with flavor, networks, etc.

**Via CLI:**
```bash
# Boot from volume
openstack server create \
  --flavor m1.small \
  --block-device-mapping vda=my-boot-volume:volume:10:false \
  --network selfservice \
  --key-name mykey \
  volume-based-vm

# Boot from volume snapshot
openstack server create \
  --flavor m1.small \
  --block-device source=snapshot,dest=volume,id=<snapshot-id>,size=20,shutdown=preserve \
  --network selfservice \
  snapshot-vm
```

## Load Balancer Management (Octavia)

### ✅ Current Status: OCTAVIA INSTALLED

**Configuration:**
- **Management Network**: lb-mgmt-net (172.16.0.0/24, VXLAN segment 300)
- **Health Manager**: 172.16.0.2 (interface o-hm0)
- **Amphora Image**: amphora-x64-haproxy (private, tagged 'amphora')
- **Amphora Flavor**: 1 vCPU, 1GB RAM, 5GB disk
- **Topology**: SINGLE (one amphora per load balancer)
- **Driver**: amphora_haproxy_rest_driver

**Horizon Integration**: Project → Network → Load Balancers

### Create Load Balancer

**Via Horizon:**
1. Navigate: **Project → Network → Load Balancers**
2. Click **Create Load Balancer**
3. **Load Balancer Details:**
   - Name = `web-lb`
   - VIP Subnet = Select your tenant subnet
   - Flavor = Leave default
4. **Listener Details:**
   - Protocol = `HTTP` or `TCP`
   - Port = `80`
   - Pool Algorithm = `ROUND_ROBIN`
5. **Pool Details:**
   - Add Pool Members (IP addresses and ports)
6. **Monitor Details** (optional):
   - Type = `HTTP` or `TCP`
   - URL Path = `/` (for HTTP)
7. Click **Create Load Balancer**

**Via CLI:**
```bash
# Create load balancer
openstack loadbalancer create --vip-subnet-id <subnet-id> --name web-lb

# Wait for ACTIVE status
watch -n 2 'openstack loadbalancer show web-lb -c provisioning_status -c operating_status'

# Create listener
openstack loadbalancer listener create \
  --protocol HTTP \
  --protocol-port 80 \
  --name web-listener \
  web-lb

# Create pool
openstack loadbalancer pool create \
  --protocol HTTP \
  --lb-algorithm ROUND_ROBIN \
  --listener web-listener \
  --name web-pool

# Add members
openstack loadbalancer member create \
  --address 10.0.0.10 \
  --protocol-port 80 \
  --subnet-id <subnet-id> \
  web-pool

openstack loadbalancer member create \
  --address 10.0.0.11 \
  --protocol-port 80 \
  --subnet-id <subnet-id> \
  web-pool

# Add health monitor
openstack loadbalancer healthmonitor create \
  --type HTTP \
  --delay 5 \
  --timeout 3 \
  --max-retries 3 \
  --url-path / \
  --expected-codes 200 \
  web-pool
```

### Load Balancer Types and Use Cases

**Layer 4 (TCP/UDP) Load Balancing:**
- **Use case**: Database clusters, message queues, generic TCP services
- **Protocol**: TCP or UDP
- **Health check**: TCP connect or UDP-CONNECT
- **Features**: Simple, high performance, protocol-agnostic

```bash
# Example: MySQL/MariaDB cluster load balancer
openstack loadbalancer create --vip-subnet-id <subnet-id> --name mysql-lb
openstack loadbalancer listener create --protocol TCP --protocol-port 3306 --name mysql-listener mysql-lb
openstack loadbalancer pool create --protocol TCP --lb-algorithm ROUND_ROBIN --listener mysql-listener --name mysql-pool
```

**Layer 7 (HTTP/HTTPS) Load Balancing:**
- **Use case**: Web applications, REST APIs, microservices
- **Protocol**: HTTP or TERMINATED_HTTPS
- **Health check**: HTTP with URL path and expected codes
- **Features**: Path-based routing, session persistence, SSL termination

```bash
# Example: Web application load balancer
openstack loadbalancer create --vip-subnet-id <subnet-id> --name app-lb
openstack loadbalancer listener create --protocol HTTP --protocol-port 80 --name app-listener app-lb
openstack loadbalancer pool create --protocol HTTP --lb-algorithm ROUND_ROBIN --listener app-listener --name app-pool
```

### Advanced Features

**Session Persistence:**
```bash
# HTTP cookie-based persistence
openstack loadbalancer pool set --session-persistence type=HTTP_COOKIE app-pool

# Source IP persistence
openstack loadbalancer pool set --session-persistence type=SOURCE_IP app-pool
```

**L7 Policies for Path-Based Routing:**
```bash
# Route /api/* to API pool
openstack loadbalancer l7policy create \
  --action REDIRECT_TO_POOL \
  --redirect-pool-id <api-pool-id> \
  --name route-api \
  app-listener

openstack loadbalancer l7rule create \
  --type PATH \
  --compare-type STARTS_WITH \
  --value /api \
  route-api
```

**Floating IP for External Access:**
```bash
# Get load balancer VIP port
LB_VIP=$(openstack loadbalancer show web-lb -f value -c vip_address)
LB_PORT_ID=$(openstack port list --fixed-ip ip-address=$LB_VIP -f value -c ID)

# Create and associate floating IP
openstack floating ip create provider
FLOATING_IP=$(openstack floating ip list --status DOWN -f value -c "Floating IP Address" | head -1)
openstack floating ip set --port $LB_PORT_ID $FLOATING_IP
```

### Monitor Load Balancer Status

**Via Horizon:**
1. Navigate: **Project → Network → Load Balancers**
2. View **Provisioning Status** and **Operating Status**
3. Click load balancer name for detailed view
4. Check **Listeners**, **Pools**, **Members**, and **Health Monitors** tabs

**Via CLI:**
```bash
# List all load balancers
openstack loadbalancer list

# Show detailed status tree
openstack loadbalancer status show web-lb

# Check amphora instances
openstack loadbalancer amphora list

# Show specific amphora details
openstack loadbalancer amphora show <amphora-id>

# Check member health
openstack loadbalancer member list web-pool
```

### Troubleshoot Load Balancer Issues

**Load balancer stuck in PENDING_CREATE:**
```bash
# Check amphora VM creation
openstack server list --all | grep amphora

# Check amphora flavor and image
openstack flavor show amphora
openstack image show amphora-x64-haproxy

# Check management network connectivity
ping 172.16.0.1  # Management network gateway
ip addr show o-hm0  # Health manager interface

# Check Octavia services
systemctl status octavia-worker
sudo journalctl -u octavia-worker -f
```

**Members showing ERROR status:**
```bash
# Check backend server is listening
telnet <member-ip> <port>

# Check security groups allow amphora access
openstack security group rule list default

# Check amphora can reach members
# (SSH to amphora instance and test connectivity)
```

**Health monitor failures:**
```bash
# Check health monitor configuration
openstack loadbalancer healthmonitor show <monitor-id>

# Verify backend service responds correctly
curl -I http://<member-ip>:<port><health-url>

# Check amphora logs (if accessible)
# SSH to amphora and check /var/log/amphora/
```

### Load Balancer Maintenance

**Update load balancer:**
```bash
# Add new member
openstack loadbalancer member create \
  --address 10.0.0.12 \
  --protocol-port 80 \
  --subnet-id <subnet-id> \
  web-pool

# Remove member
openstack loadbalancer member delete web-pool <member-id>

# Update member weight
openstack loadbalancer member set --weight 2 web-pool <member-id>

# Disable member (drain connections)
openstack loadbalancer member set --disable web-pool <member-id>
```

**Failover amphora:**
```bash
# Force amphora rebuild (for maintenance or issues)
openstack loadbalancer failover web-lb

# Wait for completion
watch -n 5 'openstack loadbalancer show web-lb -c provisioning_status'
```

**Delete load balancer:**
```bash
# Delete in reverse order: members, monitors, pools, listeners, load balancer
openstack loadbalancer member delete web-pool <member-id>
openstack loadbalancer healthmonitor delete <monitor-id>
openstack loadbalancer pool delete web-pool
openstack loadbalancer listener delete web-listener
openstack loadbalancer delete web-lb
```

### Load Balancer Best Practices

**Health Monitoring:**
- Use HTTP health checks with specific endpoints (e.g., `/health`, `/status`)
- Set appropriate timeout and retry values for your application
- Monitor both TCP connectivity and application-level health

**Session Persistence:**
- Use HTTP_COOKIE for web applications requiring session affinity
- Use SOURCE_IP for simple client affinity
- Avoid persistence if possible for better load distribution

**Pool Algorithm Selection:**
- `ROUND_ROBIN`: Equal distribution, good default
- `LEAST_CONNECTIONS`: Route to server with fewest active connections
- `SOURCE_IP`: Hash-based routing for consistent client-to-server mapping

**Security:**
- Use security groups to restrict amphora management network access
- Implement proper firewall rules for load balancer VIPs
- Consider SSL/TLS termination at the load balancer for better performance

**Performance:**
- Monitor amphora resource usage (CPU, memory, network)
- Use multiple load balancers for high-availability requirements
- Consider ACTIVE_STANDBY topology for production workloads

## Heat Orchestration

### Create Stack from Template

**Via Horizon:**
1. Navigate: **Project → Orchestration → Stacks**
2. Click **Launch Stack**
3. **Template Source** = Direct Input or File Upload
4. Paste or upload your HOT template
5. Click **Next**
6. **Stack Name** = `my-web-stack`
7. Fill in any template parameters
8. Click **Launch**

**Via CLI:**
```bash
# Create simple template file
cat > simple-vm.yaml <<'EOF'
heat_template_version: 2021-04-16
description: Simple VM with floating IP

resources:
  my_instance:
    type: OS::Nova::Server
    properties:
      flavor: m1.tiny
      image: cirros
      networks:
        - network: selfservice
      key_name: mykey
      
  floating_ip:
    type: OS::Neutron::FloatingIP
    properties:
      floating_network: provider
      
  association:
    type: OS::Neutron::FloatingIPAssociation
    properties:
      floatingip_id: { get_resource: floating_ip }
      port_id: { get_attr: [my_instance, addresses, selfservice, 0, port] }

outputs:
  instance_ip:
    value: { get_attr: [floating_ip, floating_ip_address] }
EOF

# Deploy stack
openstack stack create -t simple-vm.yaml my-web-stack

# Monitor stack creation
watch -n 2 'openstack stack list'

# Show stack resources
openstack stack resource list my-web-stack

# Get stack outputs
openstack stack output list my-web-stack
openstack stack output show my-web-stack instance_ip

# Delete stack
openstack stack delete my-web-stack
```

## Monitoring and Troubleshooting

### Check Service Status

**Via Horizon:**
1. Login as admin
2. Navigate: **Admin → System → System Information**
3. View **Compute Services**, **Network Agents**, **Block Storage Services**

**Via CLI:**
```bash
# Nova services
openstack compute service list

# Neutron agents
openstack network agent list

# Cinder services
openstack volume service list

# Placement resource providers
openstack resource provider list
```

### View Resource Usage

**Via Horizon:**
1. Navigate: **Project → Compute → Overview**
2. View quotas and usage graphs

**Via CLI:**
```bash
# Show quotas
openstack quota show

# Hypervisor statistics
openstack hypervisor stats show

# Project usage
openstack usage show

# Flavors and their specs
openstack flavor list --long
```

### View Logs and Events

**Via Horizon:**
1. Navigate to specific resource (instance, volume, etc.)
2. Click resource name for detailed view
3. Check **Log** or **Action Log** tabs

**Via CLI:**
```bash
# Instance events
openstack server event list my-test-vm

# Console log
openstack console log show my-test-vm

# List all projects and users
openstack project list
openstack user list
```

### Common Troubleshooting Commands

```bash
# Check if instance can reach metadata service
# (from inside VM)
curl http://169.254.169.254/latest/meta-data/

# Test floating IP connectivity
ping <FLOATING_IP>

# Octavia services
openstack loadbalancer provider list

# Check amphora instances
openstack loadbalancer amphora list

# Verify neutron port binding
openstack port list --server my-test-vm

# Check security group rules
openstack security group rule list default

# Force instance state update
openstack server set --state active my-test-vm

# Rescue mode (if instance won't boot)
openstack server rescue my-test-vm --image cirros
# ... troubleshoot ...
openstack server unrescue my-test-vm
```

## Quota Management

### Check Current Quotas

**Via Horizon:**
1. Login as admin
2. Navigate: **Admin → System → Defaults**
3. View **Compute Quotas**, **Volume Quotas**, **Network Quotas**

For project-specific:
1. Navigate: **Identity → Projects**
2. Click dropdown next to project
3. Select **Modify Quotas**

**Via CLI:**
```bash
# Show current project quotas
openstack quota show

# Show specific quota types
openstack quota show --compute
openstack quota show --volume
openstack quota show --network

# Show quotas for specific project
openstack quota show --project demo

# Show default quotas
openstack quota show --default
```

### Modify Quotas

**Via Horizon:**
1. Navigate: **Admin → System → Defaults** (for defaults)
   Or **Identity → Projects → Modify Quotas** (for specific project)
2. Update desired limits
3. Click **Update Defaults** or **Update Quotas**

**Via CLI:**
```bash
# Increase volume quotas (common for lab environments)
openstack quota set --volumes 50 --gigabytes 2000 admin
openstack quota set --volumes 25 --gigabytes 500 demo

# Increase compute quotas
openstack quota set --instances 20 --cores 40 --ram 81920 admin

# Network quotas
openstack quota set --networks 10 --subnets 20 --ports 100 admin

# Set unlimited (use -1)
openstack quota set --volumes -1 --gigabytes -1 admin

# Reset to defaults
openstack quota set --reset admin
```

### Common Quota Issues and Solutions

**Volume Limit Exceeded:**
```bash
# Error: Maximum number of volumes allowed (10) exceeded

# Solution 1: Clean up unused volumes
openstack volume list --status error
openstack volume delete <error-volume-ids>

# Solution 2: Increase quota
openstack quota set --volumes 50 <project-name>
```

**Instance Limit Exceeded:**
```bash
# Error: Quota exceeded for instances

# Check current usage
openstack server list --all
openstack quota show --compute

# Increase quota
openstack quota set --instances 25 <project-name>
```

**Storage Quota Exceeded:**
```bash
# Error: Requested volume size exceeds available quota

# Check volume usage
openstack volume list
openstack quota show --volume

# Increase storage quota (in GB)
openstack quota set --gigabytes 5000 <project-name>
```

### Recommended Lab Quotas

For learning/development environments:

```bash
# Liberal quotas for experimentation
openstack quota set \
  --instances 50 \
  --cores 100 \
  --ram 204800 \
  --volumes 100 \
  --gigabytes 10000 \
  --snapshots 50 \
  --networks 20 \
  --subnets 40 \
  --ports 200 \
  --floating-ips 20 \
  admin

# More restrictive for demo users
openstack quota set \
  --instances 10 \
  --cores 20 \
  --ram 40960 \
  --volumes 20 \
  --gigabytes 1000 \
  --snapshots 10 \
  --networks 5 \
  --subnets 10 \
  --ports 50 \
  --floating-ips 5 \
  demo
```

## OVN Administration

### Overview

Open Virtual Network (OVN) provides advanced software-defined networking for OpenStack Neutron. After migrating from ML2/LinuxBridge to ML2/OVN using `scripts/12-ovn-migration.sh`, the networking architecture changes significantly.

### OVN Architecture

**OVN Components:**
- **OVN Northbound DB** (ovn-nb): High-level logical network configuration
- **OVN Southbound DB** (ovn-sb): Low-level physical/logical mappings  
- **ovn-northd**: Translates northbound to southbound configurations
- **ovn-controller**: Local agent on compute nodes, manages OVS
- **neutron-ovn-metadata-agent**: Metadata proxy service

**Replaced Services:**
- ❌ `neutron-linuxbridge-agent` → ✅ `ovn-controller`
- ❌ `neutron-dhcp-agent` → ✅ Native OVN DHCP
- ❌ `neutron-l3-agent` → ✅ Native OVN routing
- ❌ `neutron-metadata-agent` → ✅ `neutron-ovn-metadata-agent`

### Daily OVN Operations

#### Check OVN Service Status

```bash
# OVN-specific services
sudo systemctl status ovn-central ovn-controller
sudo systemctl status neutron-ovn-metadata-agent

# OpenStack network agents (should show OVN agents)
openstack network agent list
# Expected: neutron-ovn-controller and neutron-ovn-metadata-agent
```

#### OVN Database Management

**Northbound Database (Logical Networks):**
```bash
# List logical switches (networks)
sudo ovn-nbctl ls-list

# Show logical switch details
sudo ovn-nbctl ls-list
sudo ovn-nbctl list Logical_Switch

# List logical routers
sudo ovn-nbctl lr-list

# Show router details
sudo ovn-nbctl list Logical_Router

# List logical ports
sudo ovn-nbctl lsp-list <logical-switch-name>

# Show port details
sudo ovn-nbctl lsp-get-addresses <port-name>
sudo ovn-nbctl lsp-get-port-security <port-name>
```

**Southbound Database (Physical Mappings):**
```bash
# List chassis (compute nodes)
sudo ovn-sbctl chassis-list

# Show chassis details
sudo ovn-sbctl show <chassis-name>

# List port bindings
sudo ovn-sbctl list Port_Binding

# Show datapath bindings
sudo ovn-sbctl list Datapath_Binding
```

#### Network Troubleshooting with OVN

**Check OVN Connectivity:**
```bash
# Test northbound database connection
sudo ovn-nbctl show

# Test southbound database connection  
sudo ovn-sbctl show

# Check if ovn-controller is connected
sudo ovs-vsctl get open . external_ids:system-id
sudo ovn-sbctl show $(sudo ovs-vsctl get open . external_ids:system-id)
```

**Trace Network Path:**
```bash
# Trace packet path through logical network
sudo ovn-trace --detailed <logical-datapath> 'inport=="<source-port>" && eth.src==<src-mac> && eth.dst==<dst-mac> && ip4.src==<src-ip> && ip4.dst==<dst-ip>'

# Example: trace from instance to external network
sudo ovn-trace --detailed neutron-<network-uuid> 'inport=="<instance-port>" && eth.src==fa:16:3e:12:34:56 && ip4.dst==8.8.8.8'
```

**Check Security Groups (ACLs):**
```bash
# List Access Control Lists
sudo ovn-nbctl list ACL

# Show ACLs for specific port
sudo ovn-nbctl acl-list <logical-switch-name>

# Find ACL by OpenStack security group
openstack security group show <security-group-id> -c id -c name
sudo ovn-nbctl --columns=external_ids list ACL | grep <security-group-id>
```

#### Performance Monitoring

**OVS Flow Tables:**
```bash
# Check OVS bridge configuration
sudo ovs-vsctl show

# List OVS flow rules
sudo ovs-ofctl dump-flows br-int

# Monitor flow statistics
watch -n 2 'sudo ovs-ofctl dump-flows br-int | head -20'

# Check for flow rule misses (performance indicator)
sudo ovs-ofctl show br-int
```

**OVN Performance Metrics:**
```bash
# Database sizes
sudo ls -lh /var/lib/ovn/ovn*.db

# Connection statistics
sudo ovn-appctl -t ovn-northd version
sudo ovn-appctl -t ovn-controller version

# Memory usage
ps aux | grep -E '(ovn|ovsdb)'
```

#### Network Configuration Changes

**Create Logical Network:**
```bash
# Via OpenStack (recommended)
openstack network create ovn-test-net
openstack subnet create --network ovn-test-net --subnet-range 192.168.200.0/24 ovn-test-subnet

# Verify in OVN
sudo ovn-nbctl ls-list | grep ovn-test-net
```

**Provider Network Configuration:**
```bash
# Check current provider network mapping
openstack network show provider -c provider:network_type -c provider:physical_network -c provider:segmentation_id

# OVN provider networks use bridge mappings
sudo ovn-nbctl list Logical_Switch | grep -A 5 'name.*provider'

# Physical bridge mapping (from ML2 config)
grep bridge_mappings /etc/neutron/plugins/ml2/ml2_conf.ini
```

#### Backup and Recovery

**Backup OVN Databases:**
```bash
# Create backup directory
sudo mkdir -p /opt/ovn-backup/$(date +%Y%m%d-%H%M)

# Backup northbound database
sudo ovsdb-client backup tcp:127.0.0.1:6641 > /opt/ovn-backup/$(date +%Y%m%d-%H%M)/nb.db

# Backup southbound database
sudo ovsdb-client backup tcp:127.0.0.1:6642 > /opt/ovn-backup/$(date +%Y%m%d-%H%M)/sb.db

# Backup configuration files
sudo cp -r /etc/neutron/ /opt/ovn-backup/$(date +%Y%m%d-%H%M)/neutron-config/
sudo cp -r /etc/openvswitch/ /opt/ovn-backup/$(date +%Y%m%d-%H%M)/ovs-config/
```

**Restore from Backup (Emergency):**
```bash
# Stop OVN services
sudo systemctl stop ovn-central ovn-controller neutron-server

# Restore databases (replace with backup file paths)
sudo ovsdb-tool restore /var/lib/ovn/ovnnb_db.db /opt/ovn-backup/20240410-1430/nb.db
sudo ovsdb-tool restore /var/lib/ovn/ovnsb_db.db /opt/ovn-backup/20240410-1430/sb.db

# Restore configuration
sudo cp -r /opt/ovn-backup/20240410-1430/neutron-config/* /etc/neutron/
sudo cp -r /opt/ovn-backup/20240410-1430/ovs-config/* /etc/openvswitch/

# Restart services
sudo systemctl start ovn-central ovn-controller neutron-server
```

#### Instance Network Debugging

**Check Instance Port Configuration:**
```bash
# Get instance port details
INSTANCE_ID=$(openstack server show test-vm -f value -c id)
PORT_ID=$(openstack port list --server $INSTANCE_ID -f value -c ID)

# Check port in OVN northbound
sudo ovn-nbctl lsp-get-addresses neutron-$PORT_ID
sudo ovn-nbctl lsp-get-port-security neutron-$PORT_ID

# Check port binding in southbound
sudo ovn-sbctl list Port_Binding | grep -A 10 neutron-$PORT_ID
```

**Network Flow Debugging:**
```bash
# Monitor OVS flows for specific port
PORT_MAC=$(openstack port show $PORT_ID -f value -c mac_address)

# Watch flows matching the instance
watch -n 1 "sudo ovs-ofctl dump-flows br-int | grep $PORT_MAC"

# Check geneve tunnel status
sudo ovs-vsctl show | grep -A 5 'Interface.*geneve'
sudo ip link show genev_sys_6081
```

#### Maintenance Operations

**Database Compaction:**
```bash
# Check database sizes
ls -lh /var/lib/ovn/ovn*.db

# Compact databases to reclaim space
sudo ovsdb-tool compact /var/lib/ovn/ovnnb_db.db
sudo ovsdb-tool compact /var/lib/ovn/ovnsb_db.db

# Restart to use compacted databases
sudo systemctl restart ovn-central
```

**Clear Stale Entries:**
```bash
# Remove stale chassis (after compute node removal)
sudo ovn-sbctl chassis-del <stale-chassis-name>

# Clean up unused logical ports
sudo ovn-nbctl --if-exists lsp-del <unused-port-name>

# Verify cleanup
sudo ovn-nbctl show
sudo ovn-sbctl show
```

#### Performance Tuning

**OVN Connection Tuning:**
```bash
# Check connection pool settings
grep -E '(ovn_nb_connection|ovn_sb_connection)' /etc/neutron/plugins/ml2/ml2_conf.ini

# For high-load environments, consider multiple connections:
# ovn_nb_connection = tcp:127.0.0.1:6641,tcp:127.0.0.1:6641
# ovn_sb_connection = tcp:127.0.0.1:6642,tcp:127.0.0.1:6642
```

**Flow Table Optimization:**
```bash
# Monitor flow table usage
sudo ovs-ofctl dump-aggregate br-int

# Check for excessive flows (may indicate issues)
sudo ovs-ofctl dump-flows br-int | wc -l
# Normal: < 1000 flows per compute node

# Clear flows if needed (temporary, will rebuild)
sudo ovs-ofctl del-flows br-int
```

### Common OVN Issues and Solutions

| Symptom | Cause | Resolution |
|---|---|---|
| Instance has no connectivity | Port binding failed | Check `ovn-controller` status, restart if needed |
| Security groups not working | ACL sync issue | Restart `neutron-server`, check `ovn-nbctl list ACL` |
| High latency between instances | Geneve tunnel issues | Check `ip link show genev_sys_6081`, verify MTU settings |
| Database growing too large | Missing cleanup of old entries | Run database compaction, clean stale entries |
| OVN services using high CPU | Large network topology | Consider splitting into smaller logical segments |
| Metadata service not working | OVN metadata agent down | Check `neutron-ovn-metadata-agent` service |

### Advantages of OVN over LinuxBridge

**Performance:**
- ✅ **Distributed routing** — L3 processing on compute nodes
- ✅ **Native ACLs** — OVN Access Control Lists vs iptables rules
- ✅ **Geneve tunneling** — more efficient than VXLAN
- ✅ **Reduced agent count** — ~5 agents per node → 2 agents per node

**Features:**
- ✅ **Built-in load balancing** — Layer 4 load balancing without Octavia
- ✅ **IPv6 support** — Full dual-stack networking
- ✅ **QoS integration** — Bandwidth limiting and prioritization
- ✅ **Advanced security** — Microsegmentation and distributed firewall

**Operations:**
- ✅ **Better debugging** — `ovn-trace` for packet path analysis
- ✅ **Centralized control** — Logical network configuration in northbound DB
- ✅ **Scalability** — Handles larger network topologies
- ✅ **State consistency** — Logical vs physical separation

### Migration Verification

After migrating to OVN, verify the system is working correctly:

```bash
# 1. Check OVN services are running
sudo systemctl status ovn-central ovn-controller neutron-ovn-metadata-agent

# 2. Verify OpenStack agents are OVN-based
openstack network agent list
# Should show: neutron-ovn-controller and neutron-ovn-metadata-agent

# 3. Test instance connectivity
openstack server create --flavor m1.tiny --image cirros --network selfservice ovn-test-vm
# Wait for ACTIVE, then test console and network

# 4. Verify security groups work
openstack security group rule create --protocol icmp default
ping <instance-ip>  # Should work

# 5. Check provider network connectivity
openstack floating ip create provider
openstack server add floating ip ovn-test-vm <floating-ip>
ping <floating-ip>  # Should work from external networks
```

## Network Troubleshooting

### Resolved Issues — Route Hijacking and Network Allocation

**Previous Problem**: Neutron LinuxBridge configuration with direct physical interface mapping caused:
- Bridge interfaces stealing host IP addresses
- "Failed to allocate the network(s)" errors
- Host routing table hijacking by OpenStack networks
- Instance creation failures in both CLI and Horizon

**Root Cause**: Physical interface mapping in `/etc/neutron/plugins/ml2/linuxbridge_agent.ini`:
```ini
# PROBLEMATIC configuration:
physical_interface_mappings = provider:wlp2s0
```

**Solution Implemented**: VXLAN-based provider networks with route protection:
```ini
# WORKING configuration:
physical_interface_mappings = 
[vxlan]
local_ip = 10.0.1.1
```

### Network Health Verification

**Check for route hijacking:**
```bash
# Verify host IP isn't stolen by bridges
ip addr show wlp2s0 | grep "inet "
ip route show default

# Should show host IP on physical interface, not bridge
```

**Verify provider network configuration:**
```bash
# Check provider network type
openstack network show provider -c provider:network_type -c provider:segmentation_id
# Should show: network_type="vxlan", segmentation_id=<ID>

# Test instance creation
openstack server create --flavor m1.tiny --image cirros --network selfservice test-net
# Should succeed without "Failed to allocate" errors
```

### Network Configuration Best Practices

1. **Use VXLAN for provider networks** — avoids physical interface conflicts
2. **Empty physical_interface_mappings** — prevents bridge IP hijacking  
3. **Integrated route protection** — installation scripts now include automatic detection
4. **Verify before deployment** — check network configuration during post-install
5. **Consider OVN migration** — Better performance, features, and debugging capabilities

## Installation Troubleshooting

### Common Installation Issues

| Symptom | Cause | Resolution |
|---|---|---|
| `openstack token issue` fails | Keystone not running or misconfigured | Check `systemctl status apache2` and `/var/log/keystone/keystone.log` |
| Nova compute not in hypervisor list | nova-compute hasn't registered yet | Run `nova-manage cell_v2 discover_hosts` and wait 30s |
| Neutron agents not showing | LinuxBridge agent crashed | Check `journalctl -u neutron-linuxbridge-agent` for bridge errors |
| Cinder volume create fails | LVM volume group not found | Verify thin provisioning: `sudo lvs cinder-volumes-file` |
| Horizon shows 500 error | Memcached connection failed | Restart memcached: `systemctl restart memcached` |
| Instance stuck in BUILD | Placement or Nova miscommunication | Check `nova-manage cell_v2 list_cells` and `openstack resource provider list` |
| "No valid host" scheduling error | Insufficient resources or placement sync | Check `openstack hypervisor stats show` and restart nova-compute |
| "Failed to allocate network" | Physical interface mapping conflict | Remove `physical_interface_mappings`, use VXLAN provider network |
| Route hijacking (host unreachable) | Bridge stole host IP address | Run integrated route protection in installation scripts |

### Known Installation Issues

| Issue | Workaround | Status |
|---|---|---|
| First installation may need service restarts | Re-run individual scripts or restart services manually | By design |
| 4 vCPU limit constrains concurrent VMs | Use m1.tiny flavor; CPU overcommit ratio set to 4x | By design |
| No TLS configured | Lab environment only — add TLS for any production use | Accepted |
| Reboot requires service restart | Re-run scripts or enable services at boot | Open |

### Installation Verification

#### Step 1: Service health check
```bash
sudo bash scripts/10-post-install.sh --verify-only
```

#### Step 2: Manual token test
```bash
source /root/admin-openrc.sh
openstack token issue
```
Expected: token data with expiry timestamp.

#### Step 3: Launch test instance
```bash
source /root/demo-openrc.sh
openstack server create --flavor m1.tiny --image cirros \
  --network selfservice --key-name mykey test-instance
openstack server list
```
Expected: instance reaches ACTIVE status within 60 seconds.

#### Step 4: Console access
```bash
openstack console url show test-instance
```
Expected: VNC URL accessible in browser.

### Installation Success Factors

- [ ] All 9 services show as active/running
- [ ] Keystone issues tokens successfully
- [ ] Glance has CirrOS image loaded
- [ ] Nova hypervisor reports available resources
- [ ] Neutron agents all report alive (no route hijacking)
- [ ] Cinder volume service is up (thin provisioning working)
- [ ] Horizon login page loads (HTTP 200)
- [ ] Heat stack list returns empty (no errors)
- [ ] Test instance reaches ACTIVE state
- [ ] VNC console accessible via browser
- [ ] Network allocation works without IP conflicts

### Complete Removal

#### Uninstall everything
```bash
sudo bash scripts/99-uninstall.sh
```

#### Individual service removal
Each script supports `--uninstall`:
```bash
sudo bash scripts/09-heat.sh --uninstall
sudo bash scripts/08-horizon.sh --uninstall
sudo bash scripts/07-cinder.sh --uninstall
# ... and so on in reverse order
```

#### Uninstall verification
```bash
# Verify no OpenStack services running
systemctl list-units --type=service | grep -E '(nova|neutron|cinder|glance|heat|keystone)'

# Verify databases removed
mysql -u root -e "SHOW DATABASES;" 2>/dev/null || echo "MariaDB removed"

# Verify packages removed
dpkg -l | grep -c openstack
```
Expected: no matches for any of the above.

## Security Considerations

- All service passwords default to `changeit` — change for any non-lab use
- MariaDB binds to 127.0.0.1 only (no remote access)
- Keystone uses Fernet tokens (cryptographically signed, stateless)
- Fernet keys stored in /etc/keystone/fernet-keys/ (root-only access)
- Admin credential file (/root/admin-openrc.sh) is mode 600
- Security groups default-deny with explicit SSH + ICMP rules

## Performance and Resource Management

This is a single-node lab deployment with no HA provisions:
- Single MariaDB instance (no replication)
- Single RabbitMQ instance (no clustering)
- Single Nova compute node
- No service redundancy

Recovery strategy: re-run the installation scripts. They are idempotent and will restore the system to a known-good state.

### System Monitoring
```bash
# Service status
openstack compute service list
openstack network agent list
openstack volume service list

# Resource usage
openstack hypervisor stats show
free -h
df -h /
```

### Monitor Resource Usage

**Via CLI:**
```bash
# Check resource usage vs quotas
openstack usage show --start $(date -d '1 month ago' '+%Y-%m-%d') --end $(date '+%Y-%m-%d')

# Hypervisor resource usage
openstack hypervisor stats show

# Project resource usage
openstack limits show --absolute

# Volume pool usage
sudo vgs cinder-volumes
sudo lvs cinder-volumes
```

## Best Practices

### Resource Naming
- Use consistent naming conventions: `<project>-<purpose>-<sequence>`
- Example: `web-frontend-01`, `db-backend-01`

### Security
- Always use key pairs, never password authentication
- Create specific security groups for different application tiers
- Use floating IPs sparingly — prefer private networks with NAT

### Storage
- Use volumes for persistent data, not instance storage
- Take regular snapshots of important volumes
- Size flavors appropriately — don't over-allocate

### Networking
- Plan IP address ranges carefully
- Use descriptive names for networks and subnets  
- Configure DNS servers in subnets

### Cleanup
- Delete unused floating IPs (they consume provider network space)
- Remove old snapshots and volumes
- Clean up failed stacks promptly

> [!NOTE]
> Last updated: 2025-01-27 — **OCTAVIA LOAD BALANCING ADDED**: Complete Octavia installation and operations guide added. Installation covers management network setup, PKI certificates, amphora image building, and Horizon integration. Operations section includes L4/L7 load balancing, health monitoring, troubleshooting, and best practices. Full air-gap compatibility maintained.

## File-Based Volume Backend Management

### Overview

The Cinder deployment uses a file-based backend stored on the internal NVMe drive at `/opt/cinder-volumes/cinder-file-backend`. This provides reliable block storage without the limitations of USB-connected devices.

### Current Configuration

- **Backend file**: `/opt/cinder-volumes/cinder-file-backend`
- **Current size**: 50GB
- **Storage location**: Internal NVMe (`/dev/mapper/ubuntu--vg-ubuntu--lv`)
- **Available host space**: ~548GB

### Expanding Volume Storage

To increase available volume storage space, expand the backend file:

```bash
# Check current file size
ls -lh /opt/cinder-volumes/cinder-file-backend

# Expand to 100GB (example)
sudo dd if=/dev/zero of=/opt/cinder-volumes/cinder-file-backend bs=1G count=100 conv=notrunc oflag=append

# Restart cinder-volume service to recognize new space
sudo systemctl restart cinder-volume

# Verify new space is available
openstack volume service list
```

### Creating Additional Backend Files

For multiple backend pools or isolation:

```bash
# Create additional backend file
sudo dd if=/dev/zero of=/opt/cinder-volumes/cinder-file-backend-2 bs=1G count=30

# Configure additional backend in /etc/cinder/cinder.conf
sudo crudini --set /etc/cinder/cinder.conf file2 volume_driver "cinder.volume.drivers.lvm.LVMVolumeDriver"
sudo crudini --set /etc/cinder/cinder.conf file2 volume_backend_name "file2"
sudo crudini --set /etc/cinder/cinder.conf file2 volume_group "cinder-volumes-file2"

# Add to enabled_backends
sudo crudini --set /etc/cinder/cinder.conf DEFAULT enabled_backends "file,file2"

# Create corresponding volume type
openstack volume type create --property volume_backend_name=file2 file2
```

### Monitoring Storage Usage

```bash
# Check host disk space
df -h /opt/cinder-volumes/

# Check volume usage
openstack volume list
openstack volume service list

# Check backend file usage
ls -lh /opt/cinder-volumes/
```

### Best Practices

1. **Size Planning**: Reserve at least 20% overhead for snapshots and metadata
2. **Monitoring**: Regularly check both file size and host disk space
3. **Backup**: Consider backing up the backend file for disaster recovery
4. **Performance**: File-based backends perform well on NVMe but may be slower than dedicated block devices

### Troubleshooting

- If volumes fail to create, check available space with `df -h /opt/cinder-volumes/`
- If service shows "down", check logs: `sudo journalctl -u cinder-volume -f`
- For space issues, either expand the file or clean up unused volumes