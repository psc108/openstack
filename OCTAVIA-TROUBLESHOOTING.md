# OCTAVIA-TROUBLESHOOTING.md

**Octavia Load Balancing Troubleshooting Guide**  
v1.0 | 2025-01-27 | Complete Installation and Configuration Issues

---

## Overview

This document covers troubleshooting for Octavia Load Balancing as a Service (LBaaS) installation and operations on the single-node OpenStack deployment. Issues range from installation problems to load balancer provisioning failures and amphora management.

## Installation Issues

## Dashboard Integration Issues

### Issue 1: Load Balancers Panel Not Visible in Horizon

**Symptoms:**
- Load Balancers panel missing from Project → Network section in Horizon
- Apache error logs show: `No policy rules for service 'load-balancer'`
- octavia-dashboard package installed but panel not appearing

**Root Causes:**
1. **Missing `load-balancer` service registration in Keystone** — Most critical issue
2. **Missing `octavia_policy.yaml` file in Horizon configuration** — Prevents panel from loading
3. **Panel files installed in user directory** — Not copied to Horizon's enabled directory
4. **Incompatible octavia-dashboard version** — Django compatibility issues

**Diagnosis Steps:**
```bash
# 1. Check if load-balancer service exists
source /root/admin-openrc.sh
openstack service list | grep load-balancer

# 2. Check for policy file
ls -la /usr/lib/python3/dist-packages/openstack_dashboard/conf/octavia_policy.yaml

# 3. Check Apache error logs
sudo tail -20 /var/log/apache2/error.log | grep -i "load-balancer\|octavia"

# 4. Check panel files
ls -la /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/*load*
find /home -name "*project_load_balancer_panel.py" 2>/dev/null
```

**Complete Resolution (Step by Step):**

**Step 1: Create load-balancer service (if missing)**
```bash
source /root/admin-openrc.sh

# Create service
openstack service create --name octavia --description "OpenStack Load Balancing" load-balancer

# Create endpoints
openstack endpoint create --region RegionOne load-balancer public http://127.0.0.1:9876
openstack endpoint create --region RegionOne load-balancer internal http://127.0.0.1:9876  
openstack endpoint create --region RegionOne load-balancer admin http://127.0.0.1:9876
```

**Step 2: Create the critical policy file**
```bash
sudo tee /usr/lib/python3/dist-packages/openstack_dashboard/conf/octavia_policy.yaml > /dev/null << 'EOF'
# Octavia Policy Rules for Horizon Dashboard
# Based on Octavia default policy and Horizon integration requirements

# Load Balancer rules
"load-balancer:read": "rule:admin_or_owner"
"load-balancer:read-global": "rule:admin_only"
"load-balancer:write": "rule:admin_or_owner"
"load-balancer:delete": "rule:admin_or_owner"

# Provider rules  
"load-balancer:provider:read": ""
"load-balancer:provider:list": ""

# Amphora rules
"load-balancer:amphora:read": "rule:admin_only"
"load-balancer:amphora:write": "rule:admin_only"
"load-balancer:amphora:delete": "rule:admin_only"

# Listener rules
"load-balancer:listener:read": "rule:admin_or_owner"
"load-balancer:listener:write": "rule:admin_or_owner" 
"load-balancer:listener:delete": "rule:admin_or_owner"

# Pool rules
"load-balancer:pool:read": "rule:admin_or_owner"
"load-balancer:pool:write": "rule:admin_or_owner"
"load-balancer:pool:delete": "rule:admin_or_owner"

# Member rules
"load-balancer:member:read": "rule:admin_or_owner"
"load-balancer:member:write": "rule:admin_or_owner"
"load-balancer:member:delete": "rule:admin_or_owner"

# Health Monitor rules
"load-balancer:health_monitor:read": "rule:admin_or_owner"
"load-balancer:health_monitor:write": "rule:admin_or_owner"
"load-balancer:health_monitor:delete": "rule:admin_or_owner"

# L7 Policy rules
"load-balancer:l7policy:read": "rule:admin_or_owner"
"load-balancer:l7policy:write": "rule:admin_or_owner"
"load-balancer:l7policy:delete": "rule:admin_or_owner"

# L7 Rule rules
"load-balancer:l7rule:read": "rule:admin_or_owner"
"load-balancer:l7rule:write": "rule:admin_or_owner"
"load-balancer:l7rule:delete": "rule:admin_or_owner"

# Quota rules
"load-balancer:quota:read": "rule:admin_only"
"load-balancer:quota:write": "rule:admin_only"
"load-balancer:quota:delete": "rule:admin_only"
EOF

sudo chmod 644 /usr/lib/python3/dist-packages/openstack_dashboard/conf/octavia_policy.yaml
```

**Step 3: Ensure panel files are in place**
```bash
# Copy from user installation if found
ENABLE_FILE=$(find /home -name "*project_load_balancer_panel.py" 2>/dev/null | head -1)
if [[ -n "$ENABLE_FILE" && -f "$ENABLE_FILE" ]]; then
    sudo cp "$ENABLE_FILE" /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/
else
    # Create manually
    sudo tee /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/_1482_project_load_balancer_panel.py > /dev/null << 'EOF'
PANEL = 'load_balancers'
PANEL_GROUP = 'network'
ADD_PANEL = 'octavia_dashboard.dashboards.project.load_balancer.panel.LoadBalancer'
EOF
fi
```

**Step 4: Clear cache and restart Apache**
```bash
# Clear Python bytecode cache
sudo find /usr/lib/python3/dist-packages/openstack_dashboard/ -name "*.pyc" -delete 2>/dev/null || true
sudo find /usr/lib/python3/dist-packages/openstack_dashboard/ -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# Restart Apache to pick up changes
sudo systemctl restart apache2
```

**Step 5: Verification**
```bash
# Check service registration
openstack service show load-balancer

# Check policy file
ls -la /usr/lib/python3/dist-packages/openstack_dashboard/conf/octavia_policy.yaml

# Check panel file
ls -la /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/*load*

# Check Apache logs for errors
sudo tail -10 /var/log/apache2/error.log
```

**Expected Result**: Load Balancers panel should now be visible in Horizon under Project → Network

**Prevention**: 
- Updated 11-octavia.sh script (v1.1+) now includes Step 17 which automatically handles all these fixes
- Always verify service registration completes during installation
- Policy file creation is now part of the standard installation process

### Issue 2: octavia-dashboard Version Compatibility

**Symptom**: No "Load Balancers" option appears under Project → Network in Horizon dashboard

**Diagnosis**:
```bash
# Check if octavia-dashboard is installed
pip3 list | grep octavia-dashboard

# Check for enable files in user installation
find /home -name "*project_load_balancer_panel.py" 2>/dev/null
find /home -name "*load_balancer_settings.py" 2>/dev/null

# Check if files are in Horizon enabled directory
ls -la /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/ | grep load
```

**Root Cause**: Octavia dashboard panel files installed in user directory but not copied to Horizon's enabled directory

**Discovery**: When octavia-dashboard is installed via `pip3 install --break-system-packages`, the files are placed in user directories (e.g., `/home/scottp/.local/lib/python3.12/site-packages/octavia_dashboard/`) rather than system-wide locations.

**Solution**:
```bash
# Method 1: Automatic discovery and copy (integrated in 11-octavia.sh v1.1+)
sudo ./11-octavia.sh  # Re-run installation script with fixed integration

# Method 2: Manual fix if needed
ENABLE_FILE=$(find /home -name "*project_load_balancer_panel.py" 2>/dev/null | head -1)
LOCAL_SETTINGS_FILE=$(find /home -name "*load_balancer_settings.py" 2>/dev/null | head -1)

if [[ -n "$ENABLE_FILE" ]]; then
    sudo cp "$ENABLE_FILE" /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/
fi

if [[ -n "$LOCAL_SETTINGS_FILE" ]]; then
    sudo mkdir -p /usr/share/openstack-dashboard/openstack_dashboard/local/local_settings.d
    sudo cp "$LOCAL_SETTINGS_FILE" /usr/share/openstack-dashboard/openstack_dashboard/local/local_settings.d/
fi

# Method 3: Manual enable file creation (fallback)
sudo tee /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/_1482_project_load_balancer_panel.py <<'EOF'
PANEL = 'load_balancers'
PANEL_GROUP = 'network'
ADD_PANEL = 'octavia_dashboard.dashboards.project.load_balancer.panel.LoadBalancer'
EOF

# Collect static files and restart Apache
cd /usr/share/openstack-dashboard
sudo python3 manage.py collectstatic --noinput
sudo python3 manage.py compress --force
sudo systemctl restart apache2
```

**Verification**: 
- Login to Horizon
- Navigate to Project → Network
- "Load Balancers" panel should be visible
- Panel number should be _1482 (not _1340 as in older versions)

### Issue 2: Package Installation Failures

**Symptom**: Installation stops during package installation phase

**Diagnosis**:
```bash
# Check package availability
apt-cache policy octavia-api octavia-health-manager octavia-housekeeping octavia-worker

# Check air-gap repository
ls /opt/openstack-airgap/debs/ | grep octavia | wc -l
```

**Root Cause**: Missing packages in air-gap download or repository issues

**Solution**:
```bash
# Re-run download to get missing packages
sudo bash scripts/00-download.sh

# Manually install if needed
sudo apt-get update
sudo apt-get install -y octavia-api octavia-health-manager octavia-housekeeping octavia-worker python3-octaviaclient
```

### Issue 3: Database Migration Failures

**Symptom**: `octavia-db-manage upgrade head` fails with connection or permission errors

**Diagnosis**:
```bash
# Test database connection
mysql -u octavia -pchangeit -h 127.0.0.1 octavia -e "SELECT 1;"

# Check octavia user permissions
sudo -u octavia octavia-db-manage --config-file /etc/octavia/octavia.conf current
```

**Root Cause**: Database user not created or configuration file permissions

**Solution**:
```bash
# Recreate database and user
mysql -u root <<EOF
DROP DATABASE IF EXISTS octavia;
CREATE DATABASE octavia;
GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'localhost' IDENTIFIED BY 'changeit';
GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'%' IDENTIFIED BY 'changeit';
FLUSH PRIVILEGES;
EOF

# Fix configuration file ownership
sudo chown octavia:octavia /etc/octavia/octavia.conf
sudo chmod 640 /etc/octavia/octavia.conf

# Run migration as octavia user
sudo -u octavia octavia-db-manage upgrade head
```

### Issue 4: PKI Certificate Generation Problems

**Symptom**: Certificate generation fails or services can't read certificates

**Diagnosis**:
```bash
# Check certificate files
ls -la /etc/octavia/certs/
openssl x509 -in /etc/octavia/certs/ca_01.pem -text -noout | grep "Not After"
```

**Root Cause**: Certificate generation errors or incorrect permissions

**Solution**:
```bash
# Regenerate certificates with proper ownership
sudo rm -rf /etc/octavia/certs
sudo mkdir -p /etc/octavia/certs/private /etc/octavia/certs/newcerts
cd /etc/octavia/certs

# Generate root CA
sudo openssl genrsa -out private/cakey.pem 4096
sudo openssl req -x509 -new -nodes -key private/cakey.pem \
    -days 3650 -out ca_01.pem -subj "/CN=Octavia Root CA"

# Generate server certificate
sudo openssl genrsa -out private/server_ca.key.pem 2048
sudo openssl req -new -key private/server_ca.key.pem \
    -out server_ca.csr -subj "/CN=Octavia Controller"
sudo openssl x509 -req -in server_ca.csr -CA ca_01.pem -CAkey private/cakey.pem \
    -CAcreateserial -out server_ca.cert.pem -days 1825
cat server_ca.cert.pem private/server_ca.key.pem | sudo tee server_ca.cert_and_key.pem > /dev/null

# Generate client certificate
sudo openssl genrsa -out private/client_ca.key.pem 2048
sudo openssl req -new -key private/client_ca.key.pem \
    -out client_ca.csr -subj "/CN=Octavia Amphora Client"
sudo openssl x509 -req -in client_ca.csr -CA ca_01.pem -CAkey private/cakey.pem \
    -CAcreateserial -out client_ca.cert.pem -days 1825
cat client_ca.cert.pem private/client_ca.key.pem | sudo tee client_ca.cert_and_key.pem > /dev/null

# Fix ownership and permissions
sudo chown -R octavia:octavia /etc/octavia/certs
sudo chmod 700 /etc/octavia/certs/private
sudo chmod 600 /etc/octavia/certs/private/*
sudo rm -f /etc/octavia/certs/*.csr
```

## Service Issues

### Issue 5: Octavia Services Failed to Start

**Symptom**: One or more Octavia services show failed status

**Diagnosis**:
```bash
# Check service status
systemctl status octavia-api octavia-health-manager octavia-housekeeping octavia-worker

# Check service logs
sudo journalctl -u octavia-api -f
sudo journalctl -u octavia-health-manager -f
sudo journalctl -u octavia-worker -f
```

**Common Root Causes**:
- Configuration file errors
- Database connection issues  
- Keystone authentication problems
- Certificate/PKI issues

**Solution**:
```bash
# Check configuration syntax
sudo octavia-api --config-file /etc/octavia/octavia.conf --help > /dev/null

# Test Keystone authentication
source /root/admin-openrc.sh
openstack --os-username octavia --os-password changeit --os-project-name service token issue

# Restart services in order
sudo systemctl restart octavia-api
sleep 2
sudo systemctl restart octavia-health-manager
sleep 2
sudo systemctl restart octavia-housekeeping
sleep 2
sudo systemctl restart octavia-worker
```

### Issue 6: Health Manager Interface Problems

**Symptom**: Health manager can't communicate with amphorae, o-hm0 interface issues

**Diagnosis**:
```bash
# Check health manager interface
ip addr show o-hm0
ip route show | grep 172.16.0

# Check port in Neutron
openstack port list | grep octavia-health-manager
```

**Root Cause**: Management network interface not properly created

**Solution**:
```bash
# Remove and recreate health manager interface
sudo ip link delete o-hm0 2>/dev/null || true
openstack port delete octavia-health-manager-port 2>/dev/null || true

# Get management network details
LB_MGMT_NET_ID=$(openstack network show lb-mgmt-net -f value -c id)
LB_MGMT_SUBNET_ID=$(openstack subnet show lb-mgmt-subnet -f value -c id)
LB_MGMT_SECGRP_ID=$(openstack security group show lb-mgmt-sec-grp -f value -c id)

# Create port
HM_PORT_ID=$(openstack port create \
    --network $LB_MGMT_NET_ID \
    --fixed-ip subnet=$LB_MGMT_SUBNET_ID,ip-address=172.16.0.2 \
    --security-group $LB_MGMT_SECGRP_ID \
    octavia-health-manager-port \
    -f value -c id)

# Create interface
sudo ip tuntap add o-hm0 mode tap
sudo ip link set o-hm0 address $(openstack port show $HM_PORT_ID -f value -c mac_address)
sudo ip addr add 172.16.0.2/24 dev o-hm0
sudo ip link set o-hm0 up

# Restart health manager
sudo systemctl restart octavia-health-manager
```

## Load Balancer Provisioning Issues

### Issue 7: Load Balancer Stuck in PENDING_CREATE

**Symptom**: Load balancer remains in PENDING_CREATE status and never becomes ACTIVE

**Diagnosis**:
```bash
# Check load balancer status
openstack loadbalancer show <lb-name> -c provisioning_status -c operating_status

# Check amphora instances
openstack loadbalancer amphora list
openstack server list --all | grep amphora

# Check worker logs
sudo journalctl -u octavia-worker -f
```

**Common Root Causes**:
1. Amphora VM failed to boot
2. Amphora image or flavor issues
3. Management network connectivity problems
4. Security group blocking communication

**Solution by Root Cause**:

**1. Amphora Boot Failure**:
```bash
# Check amphora flavor and image
openstack flavor show amphora
openstack image show amphora-x64-haproxy

# Check compute resources
openstack hypervisor stats show

# Check Nova logs
sudo journalctl -u nova-compute -f
```

**2. Image/Flavor Issues**:
```bash
# Recreate amphora image (simplified)
openstack image delete amphora-x64-haproxy 2>/dev/null || true
qemu-img create -f qcow2 /tmp/amphora-test.qcow2 2G

openstack image create amphora-x64-haproxy \
    --disk-format qcow2 \
    --container-format bare \
    --tag amphora \
    --private \
    --file /tmp/amphora-test.qcow2

# Recreate flavor if needed
openstack flavor delete amphora 2>/dev/null || true
openstack flavor create --id 200 \
    --vcpus 1 --ram 1024 --disk 5 \
    amphora --private
```

**3. Management Network Issues**:
```bash
# Test management network connectivity
ping 172.16.0.1  # Gateway
openstack subnet show lb-mgmt-subnet

# Recreate management network if needed
openstack network delete lb-mgmt-net
openstack network create lb-mgmt-net --provider-network-type vxlan --provider-segment 300
openstack subnet create lb-mgmt-subnet \
    --network lb-mgmt-net \
    --subnet-range 172.16.0.0/24 \
    --gateway 172.16.0.1 \
    --allocation-pool start=172.16.0.10,end=172.16.0.200
```

### Issue 8: Amphora Health Check Failures

**Symptom**: Load balancer shows OFFLINE operating status, amphorae not responding

**Diagnosis**:
```bash
# Check amphora status
openstack loadbalancer amphora list
openstack loadbalancer amphora show <amphora-id>

# Check health manager logs
sudo journalctl -u octavia-health-manager -f

# Test UDP connectivity
nc -u 172.16.0.2 5555  # Health manager port
```

**Root Cause**: Network connectivity between amphorae and health manager

**Solution**:
```bash
# Check and fix security groups
openstack security group rule list lb-health-mgr-sec-grp
openstack security group rule list lb-mgmt-sec-grp

# Add missing rules if needed
openstack security group rule create --protocol udp --dst-port 5555 lb-health-mgr-sec-grp
openstack security group rule create --protocol tcp --dst-port 9443 lb-health-mgr-sec-grp

# Restart health manager
sudo systemctl restart octavia-health-manager
```

### Issue 9: Load Balancer Member Issues

**Symptom**: Load balancer members show ERROR status or traffic not flowing correctly

**Diagnosis**:
```bash
# Check member status
openstack loadbalancer member list <pool-name>
openstack loadbalancer member show <pool-name> <member-id>

# Check pool and health monitor
openstack loadbalancer pool show <pool-name>
openstack loadbalancer healthmonitor show <monitor-id>
```

**Common Root Causes**:
1. Backend server not accessible
2. Wrong member IP/port configuration
3. Health monitor configuration issues
4. Security group blocking amphora-to-member traffic

**Solutions**:

**1. Backend Accessibility**:
```bash
# Test from controller
telnet <member-ip> <member-port>
curl http://<member-ip>:<member-port>/

# Check member server status
ssh <member-ip> "netstat -tlnp | grep <member-port>"
```

**2. Configuration Issues**:
```bash
# Update member configuration
openstack loadbalancer member set \
    --address <correct-ip> \
    --protocol-port <correct-port> \
    <pool-name> <member-id>
```

**3. Health Monitor Issues**:
```bash
# Fix HTTP health monitor
openstack loadbalancer healthmonitor set \
    --url-path /health \
    --expected-codes 200 \
    <monitor-id>

# Or use TCP monitor for simplicity
openstack loadbalancer healthmonitor delete <monitor-id>
openstack loadbalancer healthmonitor create \
    --type TCP \
    --delay 5 \
    --timeout 3 \
    --max-retries 3 \
    <pool-name>
```

## Network Integration Issues

### Issue 10: Route Hijacking by Octavia

**Symptom**: Host networking disrupted after Octavia installation, similar to previous Neutron issues

**Diagnosis**:
```bash
# Check for IP conflicts
ip route show default
ip addr show | grep -E "(wlp|eth|ens)"

# Check for bridge IP hijacking
brctl show
ip addr show | grep br-
```

**Root Cause**: Management network interfering with host networking

**Solution**:
```bash
# Use isolated management network (already implemented in script)
# VXLAN-based lb-mgmt-net avoids physical interface conflicts

# If issues persist, check management network configuration
openstack network show lb-mgmt-net -c provider:network_type -c provider:segmentation_id

# Should show: network_type="vxlan", segmentation_id=300
```

## Diagnostic Commands Summary

### Service Health Check
```bash
# Service status
systemctl status octavia-api octavia-health-manager octavia-housekeeping octavia-worker

# Service logs
sudo journalctl -u octavia-worker -n 50
sudo journalctl -u octavia-health-manager -n 50

# Configuration test
sudo octavia-api --config-file /etc/octavia/octavia.conf --help > /dev/null
```

### Octavia Resource Status
```bash
# Providers and capabilities
openstack loadbalancer provider list
openstack loadbalancer flavor list
openstack loadbalancer flavorprofile list

# Amphorae
openstack loadbalancer amphora list
openstack server list --all | grep amphora

# Load balancers
openstack loadbalancer list
openstack loadbalancer status show <lb-name>
```

### Network and Connectivity
```bash
# Management network
openstack network show lb-mgmt-net
openstack subnet show lb-mgmt-subnet
ip addr show o-hm0

# Security groups
openstack security group show lb-health-mgr-sec-grp
openstack security group show lb-mgmt-sec-grp

# Connectivity tests
ping 172.16.0.1  # Management gateway
nc -u 172.16.0.2 5555  # Health manager
```

### Resource Requirements
```bash
# Check available resources
openstack hypervisor stats show
openstack quota show

# Check amphora requirements
openstack flavor show amphora
openstack image show amphora-x64-haproxy
```

## Current Status: Installation and Testing Phase

**Current Status**: ✅ **RESOLVED** - Load Balancers panel integration fixed
**Critical Discovery**: Missing `octavia_policy.yaml` file and `load-balancer` service registration
**Script Updates**: ✅ 11-octavia.sh v1.2 with Step 17 policy file creation
**Dashboard Integration**: ✅ Fully functional - Panel visible in Project → Network
**Management Network**: ✅ Created (lb-mgmt-net, VXLAN segment 300)
**PKI Certificates**: ✅ Generated with proper permissions
**Service Status**: 🔄 Ready for testing

**Key Discovery**: 
- octavia-dashboard installs to user directories (`/home/user/.local/lib/python3.12/site-packages/`) when using `--break-system-packages`
- Dashboard panel files have evolved: `_1482_project_load_balancer_panel.py` (not `_1340` from older versions)
- Both enable files and local settings files need to be copied for full functionality

**Next Steps**:
1. ✅ Re-run updated 11-octavia.sh script 
2. 🔄 Test basic load balancer creation
3. 🔄 Verify amphora provisioning
4. 🔄 Test load balancing functionality

---

> **Note**: This document will be updated as issues are discovered and resolved during testing and operation of the Octavia service.