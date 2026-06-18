#!/usr/bin/env bash
# =============================================================================
# 11-octavia-simple.sh — Simple Working Octavia Installation
# =============================================================================
# Based on the minimal configuration that actually worked
# =============================================================================
set -euo pipefail

OCTAVIA_DBPASS="changeit"
OCTAVIA_PASS="changeit"

# =============================================================================
# Uninstall mode
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Uninstalling Octavia ==="
    
    systemctl stop octavia-api 2>/dev/null || true
    systemctl disable octavia-api 2>/dev/null || true
    
    apt-get purge -y octavia-api python3-octaviaclient 2>/dev/null || true
    
    rm -rf /etc/octavia
    
    mysql -u root <<EOF 2>/dev/null || true
DROP DATABASE IF EXISTS octavia;
DROP USER IF EXISTS 'octavia'@'localhost';
DROP USER IF EXISTS 'octavia'@'%';
FLUSH PRIVILEGES;
EOF
    
    source /root/admin-openrc.sh 2>/dev/null || true
    openstack user delete octavia 2>/dev/null || true
    openstack service delete octavia 2>/dev/null || true
    
    echo "Octavia uninstallation complete."
    exit 0
fi

# =============================================================================
# Verification mode
# =============================================================================
if [[ "${1:-}" == "--verify" ]]; then
    echo "=== Verifying Octavia Installation ==="
    
    echo -n "Service status: "
    systemctl is-active octavia-api 2>/dev/null || echo "inactive"
    
    echo -n "API test: "
    if curl -s http://127.0.0.1:9876/ >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAIL"
    fi
    
    source /root/admin-openrc.sh 2>/dev/null || true
    echo -n "Service registered: "
    openstack service show octavia >/dev/null 2>&1 && echo "OK" || echo "FAIL"
    
    exit 0
fi

# =============================================================================
# Installation
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)." >&2
    exit 1
fi

if [[ ! -f "/root/admin-openrc.sh" ]]; then
    echo "ERROR: /root/admin-openrc.sh not found. Run 02-keystone.sh first." >&2
    exit 1
fi

echo "=== Installing Octavia (Simple Configuration) ==="

# Stop existing services
systemctl stop octavia-api 2>/dev/null || true
rm -rf /etc/octavia

# Install packages
apt-get update -qq
apt-get install -y octavia-api python3-octaviaclient

# Create user
if ! id octavia >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/octavia --create-home --shell /bin/false octavia
fi

# Database setup
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS octavia;
GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'localhost' IDENTIFIED BY '$OCTAVIA_DBPASS';
GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'%' IDENTIFIED BY '$OCTAVIA_DBPASS';
FLUSH PRIVILEGES;
EOF

# Keystone setup
source /root/admin-openrc.sh

openstack user create --domain default --password $OCTAVIA_PASS octavia 2>/dev/null || \
    openstack user set --password $OCTAVIA_PASS octavia

openstack role add --project service --user octavia admin 2>/dev/null || true

# Remove existing service to avoid duplicates
LB_SERVICE_ID=$(openstack service list --name octavia -f value -c ID 2>/dev/null | head -1)
if [[ -n "$LB_SERVICE_ID" ]]; then
    openstack service delete "$LB_SERVICE_ID"
fi

openstack service create --name octavia --description "OpenStack Load Balancing" load-balancer
LB_SERVICE_ID=$(openstack service show octavia -f value -c id)

openstack endpoint create --region RegionOne "$LB_SERVICE_ID" public http://127.0.0.1:9876
openstack endpoint create --region RegionOne "$LB_SERVICE_ID" internal http://127.0.0.1:9876
openstack endpoint create --region RegionOne "$LB_SERVICE_ID" admin http://127.0.0.1:9876

# Create configuration directory
mkdir -p /etc/octavia

# Simple working configuration
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

# Create policy file (THE KEY FIX)
cat > /etc/octavia/policy.yaml <<EOF
# Load balancer operations
"load-balancer:read": "rule:admin_or_owner"
"load-balancer:read-global": "rule:admin_only"
"load-balancer:write": "rule:admin_or_owner"
"load-balancer:read-quota": "rule:admin_or_owner"
"load-balancer:read-quota-global": "rule:admin_only"
"load-balancer:write-quota": "rule:admin_only"

# Listener operations
"listener:read": "rule:admin_or_owner"
"listener:write": "rule:admin_or_owner"

# Pool operations
"pool:read": "rule:admin_or_owner"
"pool:write": "rule:admin_or_owner"

# Member operations
"member:read": "rule:admin_or_owner"
"member:write": "rule:admin_or_owner"

# Health monitor operations
"healthmonitor:read": "rule:admin_or_owner"
"healthmonitor:write": "rule:admin_or_owner"

# Quota operations
"quota:read": "rule:admin_or_owner"
"quota:write": "rule:admin_only"

# Provider operations
"provider:read": "rule:admin_or_owner"
EOF

# Set permissions
chown -R octavia:octavia /etc/octavia
chmod 640 /etc/octavia/octavia.conf

# Initialize database
sudo -u octavia octavia-db-manage upgrade head

# Start service
systemctl restart octavia-api
systemctl enable octavia-api

echo ""
echo "=== Octavia Installation Complete ==="
echo "  API service running on port 9876"
echo "  Policy file configured for dashboard access"
echo ""
echo "Test with:"
echo "  sudo bash 11-octavia-simple.sh --verify"
echo "  curl http://127.0.0.1:9876/"