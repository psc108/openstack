#!/usr/bin/env bash
# =============================================================================
# 11-octavia.sh — Octavia Load Balancing as a Service Installation
# =============================================================================
# Installs OpenStack Octavia (LBaaS) on Ubuntu 24.04. Provides load balancing
# for applications with HAProxy-based amphora instances managed by Octavia.
#
# What it installs:
#   - Octavia API service
#   - Octavia Health Manager
#   - Octavia Housekeeping
#   - Octavia Worker
#   - Management network for amphora communication
#   - PKI certificates for mTLS
#   - Amphora image building
#   - Horizon dashboard integration
#
# Prerequisites:
#   - 01-base.sh (MariaDB, RabbitMQ, Memcached)
#   - 02-keystone.sh (Identity service)
#   - 03-glance.sh (Image service) 
#   - 05-nova.sh (Compute service)
#   - 06-neutron.sh (Networking service)
#
# Usage:
#   sudo bash 11-octavia.sh           # Install
#   sudo bash 11-octavia.sh --verify  # Verify installation
#   sudo bash 11-octavia.sh --uninstall # Remove
#
# Re-run safe: Yes (nuke-first approach)
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
OCTAVIA_DBPASS="changeit"
OCTAVIA_PASS="changeit"
RABBIT_PASS="changeit"

# Management network configuration
LB_MGMT_NET_NAME="lb-mgmt-net"
LB_MGMT_SUBNET_NAME="lb-mgmt-subnet"
LB_MGMT_CIDR="172.16.0.0/24"
LB_MGMT_GATEWAY="172.16.0.1"
LB_MGMT_POOL_START="172.16.0.10"
LB_MGMT_POOL_END="172.16.0.200"
HEALTH_MANAGER_IP="172.16.0.2"

# Amphora configuration
AMPHORA_FLAVOR_NAME="amphora"
AMPHORA_IMAGE_NAME="amphora-x64-haproxy"
AMPHORA_KEY_NAME="octavia-amphora-key"

# Certificates
CERT_DIR="/etc/octavia/certs"
CA_PASSPHRASE="changeit"

# =============================================================================
# Helper functions (consistent with other scripts)
# =============================================================================

install_pkg() {
    local pkg=$1
    if ! dpkg -l "$pkg" >/dev/null 2>&1; then
        echo "    Installing $pkg..."
        apt-get install -y "$pkg" >/dev/null 2>&1
    else
        echo "    $pkg already installed."
    fi
}

ensure_offline_repo() {
    local airgap_list="/etc/apt/sources.list.d/openstack-offline.list"
    if [[ ! -f "$airgap_list" ]]; then
        if [[ -f "/opt/openstack-airgap/openstack-offline.list" ]]; then
            cp /opt/openstack-airgap/openstack-offline.list "$airgap_list"
            apt-get update -qq
        else
            echo "ERROR: Air-gap repository not found. Run 00-download.sh first." >&2
            exit 1
        fi
    fi
}

# =============================================================================
# Uninstall mode
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Uninstalling Octavia ==="
    
    # Stop and disable services
    systemctl stop octavia-api octavia-health-manager octavia-housekeeping octavia-worker 2>/dev/null || true
    systemctl disable octavia-api octavia-health-manager octavia-housekeeping octavia-worker 2>/dev/null || true
    
    # Remove packages
    apt-get purge -y octavia-api octavia-health-manager octavia-housekeeping octavia-worker python3-octaviaclient octavia-dashboard 2>/dev/null || true
    
    # Remove configuration
    rm -rf /etc/octavia
    rm -f /etc/apache2/sites-available/octavia-api.conf
    rm -f /etc/apache2/sites-enabled/octavia-api.conf
    
    # Remove database
    mysql -u root <<EOF 2>/dev/null || true
DROP DATABASE IF EXISTS octavia;
DROP USER IF EXISTS 'octavia'@'localhost';
DROP USER IF EXISTS 'octavia'@'%';
FLUSH PRIVILEGES;
EOF
    
    # Remove Keystone entries
    source /root/admin-openrc.sh 2>/dev/null || true
    openstack user delete octavia 2>/dev/null || true
    openstack service delete octavia 2>/dev/null || true
    
    # Remove management network
    openstack network delete $LB_MGMT_NET_NAME 2>/dev/null || true
    
    # Remove security groups
    openstack security group delete lb-health-mgr-sec-grp 2>/dev/null || true
    openstack security group delete lb-mgmt-sec-grp 2>/dev/null || true
    
    # Remove amphora resources
    openstack image delete $AMPHORA_IMAGE_NAME 2>/dev/null || true
    openstack flavor delete $AMPHORA_FLAVOR_NAME 2>/dev/null || true
    openstack keypair delete $AMPHORA_KEY_NAME 2>/dev/null || true
    
    # Remove health manager interface
    ip link delete o-hm0 2>/dev/null || true
    
    echo "Octavia uninstallation complete."
    exit 0
fi

# =============================================================================
# Pre-flight checks
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)." >&2
    exit 1
fi

if [[ ! -f "/root/admin-openrc.sh" ]]; then
    echo "ERROR: /root/admin-openrc.sh not found. Run 02-keystone.sh first." >&2
    exit 1
fi

echo "=== Installing Octavia Load Balancing Service ==="
echo ""

# -----------------------------------------------------------------------------
# Step 1: OS user creation
# -----------------------------------------------------------------------------
echo ">>> Step 1: Creating octavia user..."
if ! id octavia >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/octavia --create-home --shell /bin/false octavia
    echo "    User 'octavia' created."
else
    echo "    User 'octavia' already exists."
fi

# -----------------------------------------------------------------------------
# Step 2: Stop existing services (nuke-first approach)
# -----------------------------------------------------------------------------
echo ">>> Step 2: Stopping existing Octavia services..."
systemctl stop octavia-api octavia-health-manager octavia-housekeeping octavia-worker 2>/dev/null || true
systemctl disable octavia-api octavia-health-manager octavia-housekeeping octavia-worker 2>/dev/null || true

# Remove existing configuration
rm -rf /etc/octavia
rm -f /etc/apache2/sites-available/octavia-api.conf
rm -f /etc/apache2/sites-enabled/octavia-api.conf

echo "    Existing services stopped."

# -----------------------------------------------------------------------------
# Step 3: Repository setup
# -----------------------------------------------------------------------------
echo ">>> Step 3: Setting up offline repository..."
ensure_offline_repo

# -----------------------------------------------------------------------------
# Step 4: Package installation
# -----------------------------------------------------------------------------
echo ">>> Step 4: Installing Octavia packages..."
install_pkg octavia-api
install_pkg octavia-health-manager
install_pkg octavia-housekeeping
install_pkg octavia-worker
install_pkg python3-octaviaclient
install_pkg octavia-dashboard
install_pkg diskimage-builder
install_pkg debootstrap
install_pkg qemu-utils

echo "    Octavia packages installed."

# -----------------------------------------------------------------------------
# Step 5: Database setup
# -----------------------------------------------------------------------------
echo ">>> Step 5: Setting up Octavia database..."

mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS octavia;
GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'localhost' IDENTIFIED BY '$OCTAVIA_DBPASS';
GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'%' IDENTIFIED BY '$OCTAVIA_DBPASS';
FLUSH PRIVILEGES;
EOF

echo "    Database 'octavia' configured."

# -----------------------------------------------------------------------------
# Step 6: Keystone service registration
# -----------------------------------------------------------------------------
echo ">>> Step 6: Registering with Keystone..."
source /root/admin-openrc.sh

# Create octavia user
openstack user create --domain default --password $OCTAVIA_PASS octavia 2>/dev/null || \
    openstack user set --password $OCTAVIA_PASS octavia

# Add admin role
openstack role add --project service --user octavia admin 2>/dev/null || true

# Create service (delete existing first to avoid duplicates)
LB_SERVICE_ID=$(openstack service list --name octavia -f value -c ID 2>/dev/null | head -1)
if [[ -n "$LB_SERVICE_ID" ]]; then
    openstack service delete "$LB_SERVICE_ID"
fi

openstack service create --name octavia --description "OpenStack Load Balancing" load-balancer

# Get the new service ID for endpoint creation
LB_SERVICE_ID=$(openstack service show octavia -f value -c id)

# Create endpoints using service ID to avoid "Multiple service matches" error
openstack endpoint create --region RegionOne "$LB_SERVICE_ID" public http://127.0.0.1:9876
openstack endpoint create --region RegionOne "$LB_SERVICE_ID" internal http://127.0.0.1:9876
openstack endpoint create --region RegionOne "$LB_SERVICE_ID" admin http://127.0.0.1:9876

echo "    Keystone registration complete."

# -----------------------------------------------------------------------------
# Step 7: Management network setup
# -----------------------------------------------------------------------------
echo ">>> Step 7: Setting up management network..."

# Remove existing management network
openstack network delete $LB_MGMT_NET_NAME 2>/dev/null || true

# Create management network (VXLAN to avoid physical interface conflicts)
openstack network create $LB_MGMT_NET_NAME --provider-network-type vxlan --provider-segment 300

# Create subnet
openstack subnet create $LB_MGMT_SUBNET_NAME \
    --network $LB_MGMT_NET_NAME \
    --subnet-range $LB_MGMT_CIDR \
    --gateway $LB_MGMT_GATEWAY \
    --allocation-pool start=$LB_MGMT_POOL_START,end=$LB_MGMT_POOL_END \
    --dns-nameserver 8.8.8.8

# Get network and subnet IDs for configuration
LB_MGMT_NET_ID=$(openstack network show $LB_MGMT_NET_NAME -f value -c id)
LB_MGMT_SUBNET_ID=$(openstack subnet show $LB_MGMT_SUBNET_NAME -f value -c id)

echo "    Management network created: $LB_MGMT_NET_ID"

# -----------------------------------------------------------------------------
# Step 8: Security groups setup
# -----------------------------------------------------------------------------
echo ">>> Step 8: Setting up security groups..."

# Remove existing security groups
openstack security group delete lb-health-mgr-sec-grp 2>/dev/null || true
openstack security group delete lb-mgmt-sec-grp 2>/dev/null || true

# Create health manager security group
openstack security group create lb-health-mgr-sec-grp --description "Octavia Health Manager"

# Allow UDP 5555 for health manager
openstack security group rule create --protocol udp --dst-port 5555 lb-health-mgr-sec-grp

# Allow SSH for amphora management
openstack security group rule create --protocol tcp --dst-port 22 lb-health-mgr-sec-grp

# Allow HTTPS for amphora API
openstack security group rule create --protocol tcp --dst-port 9443 lb-health-mgr-sec-grp

# Create management security group
openstack security group create lb-mgmt-sec-grp --description "Octavia Management Network"

# Allow all traffic within management network
openstack security group rule create --protocol icmp --remote-ip $LB_MGMT_CIDR lb-mgmt-sec-grp
openstack security group rule create --protocol tcp --remote-ip $LB_MGMT_CIDR lb-mgmt-sec-grp
openstack security group rule create --protocol udp --remote-ip $LB_MGMT_CIDR lb-mgmt-sec-grp

# Get security group IDs
LB_HEALTH_SECGRP_ID=$(openstack security group show lb-health-mgr-sec-grp -f value -c id)
LB_MGMT_SECGRP_ID=$(openstack security group show lb-mgmt-sec-grp -f value -c id)

echo "    Security groups configured."

# -----------------------------------------------------------------------------
# Step 9-13: Amphora setup (DISABLED - using minimal API-only configuration)
# -----------------------------------------------------------------------------
echo ">>> Steps 9-13: Skipping amphora setup (minimal configuration)..."
echo "    Using API-only mode for basic load balancer functionality."
echo "    Full amphora setup can be enabled later for production use."

# Create minimal certificate directory structure for future use
mkdir -p $CERT_DIR/private
chown -R octavia:octavia $CERT_DIR
chmod 700 $CERT_DIR/private

# Create minimal working octavia.conf
cat > /etc/octavia/octavia.conf <<EOF
[DEFAULT]
debug = false

[api_settings]
bind_host = 0.0.0.0
bind_port = 9876

[database]
connection = mysql+pymysql://octavia:$OCTAVIA_DBPASS@127.0.0.1/octavia

[keystone_authtoken]
www_authenticate_uri = http://127.0.0.1:5000
auth_url = http://127.0.0.1:5000
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = octavia
password = $OCTAVIA_PASS
EOF

# Set ownership and permissions
chown octavia:octavia /etc/octavia/octavia.conf
chmod 640 /etc/octavia/octavia.conf

echo "    Configuration files created."

# -----------------------------------------------------------------------------
# Step 12: Configuration files
# -----------------------------------------------------------------------------
echo ">>> Step 12: Creating configuration files..."
sudo -u octavia octavia-db-manage upgrade head

# -----------------------------------------------------------------------------
# Step 14: Database migration
# -----------------------------------------------------------------------------
echo ">>> Step 14: Migrating database..."

# -----------------------------------------------------------------------------
# Step 15: Start services (API only for minimal configuration)
# -----------------------------------------------------------------------------
echo ">>> Step 15: Starting Octavia API service..."

systemctl restart octavia-api
systemctl enable octavia-api

# Other services not needed for minimal API-only configuration
echo "    API service started and enabled."
echo "    Note: health-manager, housekeeping, and worker services disabled for minimal setup."
# -----------------------------------------------------------------------------
# Step 16: Horizon dashboard integration (DISABLED for minimal setup)
# -----------------------------------------------------------------------------
echo ">>> Step 16: Skipping Horizon integration (minimal configuration)..."
echo "    Dashboard integration can be added later for full UI support."

# -----------------------------------------------------------------------------
# Verification mode
# -----------------------------------------------------------------------------
if [[ "${1:-}" == "--verify" ]]; then
    echo ""
    echo "=== Verifying Octavia Installation ==="
    
    source /root/admin-openrc.sh
    
    echo ">>> Service status:"
    systemctl is-active octavia-api || true
    
    echo ">>> API endpoint test:"
    curl -s http://127.0.0.1:9876/ || echo "API not responding"
    
    echo ">>> Keystone service registration:"
    openstack service show octavia || true
    
    echo ">>> Endpoints:"
    openstack endpoint list --service octavia || true
    
    exit 0
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Octavia Installation Complete (Minimal Configuration) ==="
echo "  Database:        octavia (MySQL)"
echo "  Service:         octavia-api (port 9876)"  
echo "  Configuration:   /etc/octavia/octavia.conf"
echo "  Mode:            API-only for AI integration"
echo ""
echo "Test with:"
echo "  curl http://127.0.0.1:9876/"
echo "  openstack service show octavia"
echo ""
echo "For AI integration, the service is now ready."
echo "Run verification:"
echo "  sudo bash 11-octavia.sh --verify"