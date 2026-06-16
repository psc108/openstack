#!/usr/bin/env bash
# =============================================================================
# 04-placement.sh — OpenStack Placement Service
# =============================================================================
# Placement tracks resource inventories and allocations across the cloud.
#
# Why Placement exists:
#   When you launch a VM, Nova needs to know which compute node has enough
#   vCPUs, RAM, and disk. Placement maintains this inventory and handles
#   the "claim" (reservation) so two VMs don't get scheduled to the same
#   resources. It was split out of Nova in the Queens release.
#
# Key concepts:
#   - Resource Providers: things that have resources (compute nodes, shared storage)
#   - Inventories: what resources a provider has (VCPU=4, MEMORY_MB=32768)
#   - Allocations: what's been claimed by consumers (instances)
#   - Traits: qualitative capabilities (HW_CPU_X86_SSE4, STORAGE_DISK_SSD)
#
# Usage:
#   sudo bash 04-placement.sh
#   sudo bash 04-placement.sh --uninstall
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
AIRGAP_DIR="/opt/openstack-airgap"
REPO_DIR="${AIRGAP_DIR}/repo"

DB_ROOT_PASS="changeit"
PLACEMENT_DB_PASS="changeit"
PLACEMENT_PASS="changeit"

CONTROLLER="localhost"
REGION="RegionOne"

# =============================================================================
# Uninstall mode
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Uninstalling Placement ==="
    apt-get purge -y placement-api 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS placement;" 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP USER IF EXISTS 'placement'@'localhost';" 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP USER IF EXISTS 'placement'@'%';" 2>/dev/null || true
    rm -rf /etc/placement
    # Restart Apache to unload the WSGI app
    systemctl restart apache2 2>/dev/null || true
    echo "=== Placement removed ==="
    exit 0
fi

# =============================================================================
# Pre-flight
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root." >&2
    exit 1
fi

source /root/admin-openrc.sh

echo "=== Installing Placement Service ==="
echo ""

install_pkg() {
    if [[ -f "${REPO_DIR}/Packages" ]] && \
       [[ ! -f /etc/apt/sources.list.d/openstack-offline.list ]]; then
        cp "${AIRGAP_DIR}/openstack-offline.list" /etc/apt/sources.list.d/
        apt-get update -qq
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# -----------------------------------------------------------------------------
# Step 1: Create database
# -----------------------------------------------------------------------------
echo ">>> Step 1: Creating Placement database..."
mariadb -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS placement;
CREATE USER IF NOT EXISTS 'placement'@'localhost' IDENTIFIED BY '${PLACEMENT_DB_PASS}';
CREATE USER IF NOT EXISTS 'placement'@'%' IDENTIFIED BY '${PLACEMENT_DB_PASS}';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%';
FLUSH PRIVILEGES;
EOF

# -----------------------------------------------------------------------------
# Step 2: Register in Keystone
# -----------------------------------------------------------------------------
echo ">>> Step 2: Registering Placement in Keystone..."

openstack user create --domain default --password "${PLACEMENT_PASS}" placement 2>/dev/null || \
    openstack user set --password "${PLACEMENT_PASS}" placement
openstack role add --project service --user placement admin 2>/dev/null || true
openstack service create --name placement --description "Placement API" placement 2>/dev/null || true

for IFACE in public internal admin; do
    openstack endpoint create --region "${REGION}" placement "${IFACE}" \
        "http://${CONTROLLER}:8778" 2>/dev/null || true
done

# -----------------------------------------------------------------------------
# Step 3: Install packages
# -----------------------------------------------------------------------------
echo ">>> Step 3: Installing Placement..."
install_pkg placement-api

# -----------------------------------------------------------------------------
# Step 4: Configure
# -----------------------------------------------------------------------------
echo ">>> Step 4: Configuring Placement..."

PLACEMENT_CONF="/etc/placement/placement.conf"

crudini --set "${PLACEMENT_CONF}" placement_database connection \
    "mysql+pymysql://placement:${PLACEMENT_DB_PASS}@${CONTROLLER}/placement"

crudini --set "${PLACEMENT_CONF}" api auth_strategy "keystone"

crudini --set "${PLACEMENT_CONF}" keystone_authtoken auth_url "http://${CONTROLLER}:5000/v3"
crudini --set "${PLACEMENT_CONF}" keystone_authtoken memcached_servers "${CONTROLLER}:11211"
crudini --set "${PLACEMENT_CONF}" keystone_authtoken auth_type "password"
crudini --set "${PLACEMENT_CONF}" keystone_authtoken project_domain_name "Default"
crudini --set "${PLACEMENT_CONF}" keystone_authtoken user_domain_name "Default"
crudini --set "${PLACEMENT_CONF}" keystone_authtoken project_name "service"
crudini --set "${PLACEMENT_CONF}" keystone_authtoken username "placement"
crudini --set "${PLACEMENT_CONF}" keystone_authtoken password "${PLACEMENT_PASS}"

# -----------------------------------------------------------------------------
# Step 5: Sync database
# -----------------------------------------------------------------------------
echo ">>> Step 5: Syncing Placement database..."
su -s /bin/sh -c "placement-manage db sync" placement

# -----------------------------------------------------------------------------
# Step 6: Restart Apache (Placement runs as WSGI inside Apache)
# -----------------------------------------------------------------------------
echo ">>> Step 6: Restarting Apache..."
systemctl restart apache2

# -----------------------------------------------------------------------------
# Step 7: Verify
# -----------------------------------------------------------------------------
echo ">>> Step 7: Verifying Placement..."

# Install osc-placement plugin for CLI verification
install_pkg python3-osc-placement 2>/dev/null || true

if openstack --os-placement-api-version 1.2 resource class list >/dev/null 2>&1; then
    echo "    ✓ Placement operational — resource classes available."
else
    echo "    ✗ ERROR: Placement not responding. Check Apache error logs."
    exit 1
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Placement Installation Complete ==="
echo ""
echo "  Endpoint:  http://${CONTROLLER}:8778"
echo ""
echo "Next: Run 05-nova.sh to install the compute service."
