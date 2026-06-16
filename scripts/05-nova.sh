#!/usr/bin/env bash
# =============================================================================
# 05-nova.sh — OpenStack Compute Service (Nova)
# =============================================================================
# Nova is the compute engine — it creates, schedules, and manages VMs.
#
# Architecture (single-node, all roles on one machine):
#
#   nova-api         — REST API frontend, accepts user requests
#   nova-scheduler   — decides which compute node runs a new instance
#   nova-conductor   — database proxy (compute nodes never touch DB directly)
#   nova-novncproxy  — VNC console proxy (browser-based console access)
#   nova-compute     — hypervisor agent (talks to libvirt/KVM to manage VMs)
#
# On a multi-node setup, nova-compute runs on dedicated compute nodes.
# Here, everything runs on the same machine — the laptop IS the compute node.
#
# Key concepts:
#   - Flavors: VM size templates (m1.tiny = 1 vCPU, 512MB RAM, 1GB disk)
#   - Images: boot disk templates (from Glance)
#   - Instances: running VMs
#   - Key pairs: SSH keys injected into instances
#   - Security groups: firewall rules for instances
#
# Hypervisor:
#   We use KVM (hardware virtualisation) if available, falling back to QEMU
#   (software emulation) if nested virt isn't supported.
#
# Usage:
#   sudo bash 05-nova.sh
#   sudo bash 05-nova.sh --uninstall
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
AIRGAP_DIR="/opt/openstack-airgap"
REPO_DIR="${AIRGAP_DIR}/repo"

DB_ROOT_PASS="changeit"
NOVA_DB_PASS="changeit"
NOVA_PASS="changeit"
PLACEMENT_PASS="changeit"
RABBIT_PASS="changeit"

CONTROLLER="localhost"
MGMT_IP="127.0.0.1"
REGION="RegionOne"

# =============================================================================
# Uninstall mode
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Uninstalling Nova ==="

    systemctl stop nova-api nova-scheduler nova-conductor \
        nova-novncproxy nova-compute 2>/dev/null || true
    systemctl disable nova-api nova-scheduler nova-conductor \
        nova-novncproxy nova-compute 2>/dev/null || true

    apt-get purge -y nova-api nova-conductor nova-novncproxy nova-scheduler \
        nova-compute qemu-kvm libvirt-daemon-system 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    mariadb -u root -p"${DB_ROOT_PASS}" <<EOF 2>/dev/null || true
DROP DATABASE IF EXISTS nova;
DROP DATABASE IF EXISTS nova_api;
DROP DATABASE IF EXISTS nova_cell0;
DROP USER IF EXISTS 'nova'@'localhost';
DROP USER IF EXISTS 'nova'@'%';
EOF

    rm -rf /etc/nova /var/lib/nova /var/log/nova
    echo "=== Nova removed ==="
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

echo "=== Installing Nova (Compute Service) ==="
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
# Step 1: Create databases
# -----------------------------------------------------------------------------
# Nova uses THREE databases:
#   nova_api  — API-level data (flavors, quotas, build requests)
#   nova      — instance data (per-cell, we have one cell: cell1)
#   nova_cell0 — special cell for instances that failed to schedule
echo ">>> Step 1: Creating Nova databases..."

mariadb -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS nova_api;
CREATE DATABASE IF NOT EXISTS nova;
CREATE DATABASE IF NOT EXISTS nova_cell0;
CREATE USER IF NOT EXISTS 'nova'@'localhost' IDENTIFIED BY '${NOVA_DB_PASS}';
CREATE USER IF NOT EXISTS 'nova'@'%' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%';
FLUSH PRIVILEGES;
EOF

# -----------------------------------------------------------------------------
# Step 2: Register in Keystone
# -----------------------------------------------------------------------------
echo ">>> Step 2: Registering Nova in Keystone..."

openstack user create --domain default --password "${NOVA_PASS}" nova 2>/dev/null || \
    openstack user set --password "${NOVA_PASS}" nova
openstack role add --project service --user nova admin 2>/dev/null || true
openstack service create --name nova --description "OpenStack Compute" compute 2>/dev/null || true

for IFACE in public internal admin; do
    openstack endpoint create --region "${REGION}" compute "${IFACE}" \
        "http://${CONTROLLER}:8774/v2.1" 2>/dev/null || true
done

# -----------------------------------------------------------------------------
# Step 3: Install packages
# -----------------------------------------------------------------------------
echo ">>> Step 3: Installing Nova packages..."
install_pkg nova-api nova-conductor nova-novncproxy nova-scheduler \
    nova-compute qemu-kvm libvirt-daemon-system libvirt-clients virtinst

# -----------------------------------------------------------------------------
# Step 4: Configure Nova
# -----------------------------------------------------------------------------
echo ">>> Step 4: Configuring Nova..."

NOVA_CONF="/etc/nova/nova.conf"

# -- API and general settings --
crudini --set "${NOVA_CONF}" api_database connection \
    "mysql+pymysql://nova:${NOVA_DB_PASS}@${CONTROLLER}/nova_api"
crudini --set "${NOVA_CONF}" database connection \
    "mysql+pymysql://nova:${NOVA_DB_PASS}@${CONTROLLER}/nova"

# RabbitMQ transport — how Nova services communicate internally
crudini --set "${NOVA_CONF}" DEFAULT transport_url \
    "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER}:5672/"

# Use Keystone for auth
crudini --set "${NOVA_CONF}" api auth_strategy "keystone"

# Keystone auth for Nova's own requests
crudini --set "${NOVA_CONF}" keystone_authtoken www_authenticate_uri "http://${CONTROLLER}:5000/"
crudini --set "${NOVA_CONF}" keystone_authtoken auth_url "http://${CONTROLLER}:5000/"
crudini --set "${NOVA_CONF}" keystone_authtoken memcached_servers "${CONTROLLER}:11211"
crudini --set "${NOVA_CONF}" keystone_authtoken auth_type "password"
crudini --set "${NOVA_CONF}" keystone_authtoken project_domain_name "Default"
crudini --set "${NOVA_CONF}" keystone_authtoken user_domain_name "Default"
crudini --set "${NOVA_CONF}" keystone_authtoken project_name "service"
crudini --set "${NOVA_CONF}" keystone_authtoken username "nova"
crudini --set "${NOVA_CONF}" keystone_authtoken password "${NOVA_PASS}"

# Service user (for long-running operations that outlive user tokens)
crudini --set "${NOVA_CONF}" service_user send_service_user_token "true"
crudini --set "${NOVA_CONF}" service_user auth_url "http://${CONTROLLER}:5000/"
crudini --set "${NOVA_CONF}" service_user auth_strategy "keystone"
crudini --set "${NOVA_CONF}" service_user auth_type "password"
crudini --set "${NOVA_CONF}" service_user project_domain_name "Default"
crudini --set "${NOVA_CONF}" service_user user_domain_name "Default"
crudini --set "${NOVA_CONF}" service_user project_name "service"
crudini --set "${NOVA_CONF}" service_user username "nova"
crudini --set "${NOVA_CONF}" service_user password "${NOVA_PASS}"

# My IP — used for VNC URLs and metadata service
crudini --set "${NOVA_CONF}" DEFAULT my_ip "${MGMT_IP}"

# VNC console access — allows browser-based console to VMs
crudini --set "${NOVA_CONF}" vnc enabled "true"
crudini --set "${NOVA_CONF}" vnc server_listen "0.0.0.0"
crudini --set "${NOVA_CONF}" vnc server_proxyclient_address "${MGMT_IP}"
crudini --set "${NOVA_CONF}" vnc novncproxy_base_url "http://${MGMT_IP}:6080/vnc_auto.html"

# Glance — where to find VM images
crudini --set "${NOVA_CONF}" glance api_servers "http://${CONTROLLER}:9292"

# Oslo concurrency lock path
crudini --set "${NOVA_CONF}" oslo_concurrency lock_path "/var/lib/nova/tmp"

# Placement — Nova reports resource usage to Placement
crudini --set "${NOVA_CONF}" placement region_name "${REGION}"
crudini --set "${NOVA_CONF}" placement project_domain_name "Default"
crudini --set "${NOVA_CONF}" placement project_name "service"
crudini --set "${NOVA_CONF}" placement auth_type "password"
crudini --set "${NOVA_CONF}" placement user_domain_name "Default"
crudini --set "${NOVA_CONF}" placement auth_url "http://${CONTROLLER}:5000/v3"
crudini --set "${NOVA_CONF}" placement username "placement"
crudini --set "${NOVA_CONF}" placement password "${PLACEMENT_PASS}"

# -- Compute (hypervisor) settings --
# Detect if KVM is available (hardware virt support)
if grep -qE '(vmx|svm)' /proc/cpuinfo; then
    VIRT_TYPE="kvm"
    echo "    Hardware virtualisation detected — using KVM."
else
    VIRT_TYPE="qemu"
    echo "    No hardware virt — falling back to QEMU (slower)."
fi

crudini --set "${NOVA_CONF}" libvirt virt_type "${VIRT_TYPE}"

# CPU allocation ratio — on a laptop, allow overcommit
# 4 physical CPUs × 4 ratio = 16 virtual CPUs available
crudini --set "${NOVA_CONF}" DEFAULT cpu_allocation_ratio "4.0"

# RAM allocation ratio — slight overcommit (1.2x)
crudini --set "${NOVA_CONF}" DEFAULT ram_allocation_ratio "1.2"

# Ensure lock directory exists
mkdir -p /var/lib/nova/tmp
chown nova:nova /var/lib/nova/tmp

# -----------------------------------------------------------------------------
# Step 5: Sync databases
# -----------------------------------------------------------------------------
echo ">>> Step 5: Syncing Nova databases..."

su -s /bin/sh -c "nova-manage api_db sync" nova
su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova 2>/dev/null || true
su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova 2>/dev/null || true
su -s /bin/sh -c "nova-manage db sync" nova
su -s /bin/sh -c "nova-manage cell_v2 list_cells" nova

# -----------------------------------------------------------------------------
# Step 6: Start services
# -----------------------------------------------------------------------------
echo ">>> Step 6: Starting Nova services..."

for SVC in nova-api nova-scheduler nova-conductor nova-novncproxy nova-compute; do
    systemctl enable --now "${SVC}"
    systemctl restart "${SVC}"
done

# Give services time to register with Placement
sleep 5

# -----------------------------------------------------------------------------
# Step 7: Discover compute hosts
# -----------------------------------------------------------------------------
# After nova-compute starts, it registers itself. We need to map it into cell1.
echo ">>> Step 7: Discovering compute hosts..."
su -s /bin/sh -c "nova-manage cell_v2 discover_hosts --verbose" nova

# -----------------------------------------------------------------------------
# Step 8: Verify
# -----------------------------------------------------------------------------
echo ">>> Step 8: Verifying Nova..."

echo "  Compute services:"
openstack compute service list

echo ""
echo "  Hypervisor stats:"
openstack hypervisor stats show 2>/dev/null || openstack hypervisor list

if openstack compute service list | grep -q "nova-compute.*up"; then
    echo ""
    echo "    ✓ Nova operational — compute node registered."
else
    echo ""
    echo "    ✗ WARNING: nova-compute not showing as 'up'. Check logs."
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Nova Installation Complete ==="
echo ""
echo "  API Endpoint:    http://${CONTROLLER}:8774/v2.1"
echo "  VNC Console:     http://${MGMT_IP}:6080/vnc_auto.html"
echo "  Hypervisor type: ${VIRT_TYPE}"
echo "  vCPU available:  $(( $(nproc) * 4 )) (4x overcommit)"
echo ""
echo "Next: Run 06-neutron.sh to install networking."
