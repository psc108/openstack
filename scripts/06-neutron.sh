#!/usr/bin/env bash
# =============================================================================
# 06-neutron.sh — OpenStack Networking Service (Neutron)
# =============================================================================
# Neutron provides networking-as-a-service — virtual networks, routers,
# firewalls, and load balancers for OpenStack instances.
#
# Architecture choice: LinuxBridge + Self-service (overlay) networks
#
# Why LinuxBridge over OVS/OVN?
#   - Simpler to understand and debug on a single node
#   - Uses standard Linux tools (brctl, iptables, ip)
#   - No external SDN controller needed
#   - Perfect for learning
#
# Network types:
#   - Provider networks: directly mapped to physical NIC (flat/VLAN)
#   - Self-service networks: tenant-created overlay (VXLAN tunnels)
#
# We configure BOTH:
#   - A flat provider network for external access (NAT to host)
#   - VXLAN self-service networks for tenant isolation
#
# Agents (all on this single node):
#   - neutron-server         — API and plugin coordination
#   - neutron-linuxbridge-agent — creates bridges and VXLAN tunnels
#   - neutron-dhcp-agent     — runs dnsmasq for VM DHCP
#   - neutron-metadata-agent — proxies metadata requests from VMs
#   - neutron-l3-agent       — virtual routers (NAT, floating IPs)
#
# Usage:
#   sudo bash 06-neutron.sh
#   sudo bash 06-neutron.sh --uninstall
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
AIRGAP_DIR="/opt/openstack-airgap"
REPO_DIR="${AIRGAP_DIR}/repo"

DB_ROOT_PASS="changeit"
NEUTRON_DB_PASS="changeit"
NEUTRON_PASS="changeit"
NOVA_PASS="changeit"
RABBIT_PASS="changeit"

CONTROLLER="localhost"
MGMT_IP="127.0.0.1"
REGION="RegionOne"

# The physical interface for the provider (external) network.
# On a laptop, this is typically the interface with your LAN/WiFi IP.
# We'll use a bridge mapped to this for external VM access.
PROVIDER_INTERFACE="$(ip route get 8.8.8.8 | awk '{print $5; exit}')"

# Metadata shared secret — Nova and Neutron must agree on this
METADATA_SECRET="changeit"

# =============================================================================
# Uninstall mode
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Uninstalling Neutron ==="
    systemctl stop neutron-server neutron-linuxbridge-agent neutron-dhcp-agent \
        neutron-metadata-agent neutron-l3-agent 2>/dev/null || true
    systemctl disable neutron-server neutron-linuxbridge-agent neutron-dhcp-agent \
        neutron-metadata-agent neutron-l3-agent 2>/dev/null || true
    apt-get purge -y neutron-server neutron-plugin-ml2 neutron-linuxbridge-agent \
        neutron-l3-agent neutron-dhcp-agent neutron-metadata-agent 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS neutron;" 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP USER IF EXISTS 'neutron'@'localhost';" 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP USER IF EXISTS 'neutron'@'%';" 2>/dev/null || true
    rm -rf /etc/neutron /var/lib/neutron /var/log/neutron
    echo "=== Neutron removed ==="
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

echo "=== Installing Neutron (Networking Service) ==="
echo "  Provider interface: ${PROVIDER_INTERFACE}"
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
echo ">>> Step 1: Creating Neutron database..."
mariadb -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS neutron;
CREATE USER IF NOT EXISTS 'neutron'@'localhost' IDENTIFIED BY '${NEUTRON_DB_PASS}';
CREATE USER IF NOT EXISTS 'neutron'@'%' IDENTIFIED BY '${NEUTRON_DB_PASS}';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%';
FLUSH PRIVILEGES;
EOF

# -----------------------------------------------------------------------------
# Step 2: Register in Keystone
# -----------------------------------------------------------------------------
echo ">>> Step 2: Registering Neutron in Keystone..."
openstack user create --domain default --password "${NEUTRON_PASS}" neutron 2>/dev/null || \
    openstack user set --password "${NEUTRON_PASS}" neutron
openstack role add --project service --user neutron admin 2>/dev/null || true
openstack service create --name neutron --description "OpenStack Networking" network 2>/dev/null || true

for IFACE in public internal admin; do
    openstack endpoint create --region "${REGION}" network "${IFACE}" \
        "http://${CONTROLLER}:9696" 2>/dev/null || true
done

# -----------------------------------------------------------------------------
# Step 3: Install packages
# -----------------------------------------------------------------------------
echo ">>> Step 3: Installing Neutron packages..."
install_pkg neutron-server neutron-plugin-ml2 \
    neutron-linuxbridge-agent neutron-l3-agent neutron-dhcp-agent neutron-metadata-agent \
    bridge-utils ebtables ipset conntrack

# -----------------------------------------------------------------------------
# Step 4: Configure Neutron server
# -----------------------------------------------------------------------------
echo ">>> Step 4: Configuring Neutron..."

NEUTRON_CONF="/etc/neutron/neutron.conf"

# Database
crudini --set "${NEUTRON_CONF}" database connection \
    "mysql+pymysql://neutron:${NEUTRON_DB_PASS}@${CONTROLLER}/neutron"

# RabbitMQ
crudini --set "${NEUTRON_CONF}" DEFAULT transport_url \
    "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER}:5672/"

# Auth
crudini --set "${NEUTRON_CONF}" DEFAULT auth_strategy "keystone"
crudini --set "${NEUTRON_CONF}" keystone_authtoken www_authenticate_uri "http://${CONTROLLER}:5000"
crudini --set "${NEUTRON_CONF}" keystone_authtoken auth_url "http://${CONTROLLER}:5000/v3"
crudini --set "${NEUTRON_CONF}" keystone_authtoken memcached_servers "${CONTROLLER}:11211"
crudini --set "${NEUTRON_CONF}" keystone_authtoken auth_type "password"
crudini --set "${NEUTRON_CONF}" keystone_authtoken project_domain_name "Default"
crudini --set "${NEUTRON_CONF}" keystone_authtoken user_domain_name "Default"
crudini --set "${NEUTRON_CONF}" keystone_authtoken project_name "service"
crudini --set "${NEUTRON_CONF}" keystone_authtoken username "neutron"
crudini --set "${NEUTRON_CONF}" keystone_authtoken password "${NEUTRON_PASS}"

# ML2 plugin — Modular Layer 2 is the standard Neutron plugin
# It supports multiple mechanism drivers (LinuxBridge, OVS, etc.)
crudini --set "${NEUTRON_CONF}" DEFAULT core_plugin "ml2"
crudini --set "${NEUTRON_CONF}" DEFAULT service_plugins "router"

# Allow overlapping IPs between tenants (standard for self-service nets)
crudini --set "${NEUTRON_CONF}" DEFAULT allow_overlapping_ips "true"

# Notify Nova when port status changes (so Nova can update instance info)
crudini --set "${NEUTRON_CONF}" DEFAULT notify_nova_on_port_status_changes "true"
crudini --set "${NEUTRON_CONF}" DEFAULT notify_nova_on_port_data_changes "true"

crudini --set "${NEUTRON_CONF}" nova auth_url "http://${CONTROLLER}:5000/v3"
crudini --set "${NEUTRON_CONF}" nova auth_type "password"
crudini --set "${NEUTRON_CONF}" nova project_domain_name "Default"
crudini --set "${NEUTRON_CONF}" nova user_domain_name "Default"
crudini --set "${NEUTRON_CONF}" nova region_name "${REGION}"
crudini --set "${NEUTRON_CONF}" nova project_name "service"
crudini --set "${NEUTRON_CONF}" nova username "nova"
crudini --set "${NEUTRON_CONF}" nova password "${NOVA_PASS}"

# Oslo concurrency
crudini --set "${NEUTRON_CONF}" oslo_concurrency lock_path "/var/lib/neutron/tmp"
mkdir -p /var/lib/neutron/tmp
chown neutron:neutron /var/lib/neutron/tmp

# LinuxBridge is marked experimental in Caracal — explicitly enable it
crudini --set "${NEUTRON_CONF}" experimental linuxbridge true

# -----------------------------------------------------------------------------
# Step 5: Configure ML2 plugin
# -----------------------------------------------------------------------------
# ML2 is the modular plugin that defines:
#   - type_drivers: what network types are supported (flat, vlan, vxlan)
#   - mechanism_drivers: how those types are implemented (linuxbridge)
#   - extension_drivers: additional features (port_security)
echo ">>> Step 5: Configuring ML2 plugin..."

ML2_CONF="/etc/neutron/plugins/ml2/ml2_conf.ini"

# Enable VXLAN as the primary network type instead of flat networks
# This avoids the need for direct physical interface mapping
crudini --set "${ML2_CONF}" ml2 type_drivers "vxlan,flat,vlan"
crudini --set "${ML2_CONF}" ml2 tenant_network_types "vxlan"
crudini --set "${ML2_CONF}" ml2 mechanism_drivers "linuxbridge,l2population"
crudini --set "${ML2_CONF}" ml2 extension_drivers "port_security"

# For provider networks, we'll rely on NAT through the router rather than
# direct flat network mapping to avoid IP conflicts
# Only configure flat networks if absolutely necessary
if false; then  # Disabled to prevent IP hijacking
    crudini --set "${ML2_CONF}" ml2_type_flat flat_networks "provider"
fi

# VXLAN — VNI range for tenant networks (each tenant network gets a unique VNI)
crudini --set "${ML2_CONF}" ml2_type_vxlan vni_ranges "1:1000"

# Security group driver
crudini --set "${ML2_CONF}" securitygroup enable_ipset "true"

# -----------------------------------------------------------------------------
# Step 6: Configure LinuxBridge agent
# -----------------------------------------------------------------------------
# The agent creates Linux bridges and VXLAN interfaces on this node.
echo ">>> Step 6: Configuring LinuxBridge agent..."

LB_CONF="/etc/neutron/plugins/ml2/linuxbridge_agent.ini"

# CRITICAL: Do NOT map provider network directly to physical interface
# This causes bridge IP hijacking and routing conflicts
# Instead, leave physical_interface_mappings empty for provider networks
# The provider network will use the default bridge without stealing the host IP
echo "    WARNING: Not mapping provider to physical interface to prevent IP hijacking"
crudini --set "${LB_CONF}" linux_bridge physical_interface_mappings ""

# Alternative: If provider network mapping is absolutely required,
# create a dedicated bridge interface instead of using the wireless interface directly
# This prevents the bridge from stealing the host's IP address
if false; then  # Disabled - causes routing problems
    crudini --set "${LB_CONF}" linux_bridge physical_interface_mappings "provider:${PROVIDER_INTERFACE}"
fi

# VXLAN settings - use management IP, not localhost
# Using localhost prevents proper tunnel communication
crudini --set "${LB_CONF}" vxlan enable_vxlan "true"
crudini --set "${LB_CONF}" vxlan local_ip "${MGMT_IP}"
crudini --set "${LB_CONF}" vxlan l2_population "true"

# Security groups via iptables
crudini --set "${LB_CONF}" securitygroup enable_security_group "true"
crudini --set "${LB_CONF}" securitygroup firewall_driver "neutron.agent.linux.iptables_firewall.IptablesFirewallDriver"

# Enable kernel module for VXLAN and bridge filtering
modprobe br_netfilter 2>/dev/null || true
sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true

# Make persistent
cat > /etc/sysctl.d/99-openstack-bridge.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# -----------------------------------------------------------------------------
# Step 7: Configure L3 agent (virtual routers)
# -----------------------------------------------------------------------------
echo ">>> Step 7: Configuring L3 agent..."

L3_CONF="/etc/neutron/l3_agent.ini"
crudini --set "${L3_CONF}" DEFAULT interface_driver "linuxbridge"

# -----------------------------------------------------------------------------
# Step 8: Configure DHCP agent
# -----------------------------------------------------------------------------
echo ">>> Step 8: Configuring DHCP agent..."

DHCP_CONF="/etc/neutron/dhcp_agent.ini"
crudini --set "${DHCP_CONF}" DEFAULT interface_driver "linuxbridge"
crudini --set "${DHCP_CONF}" DEFAULT dhcp_driver "neutron.agent.linux.dhcp.Dnsmasq"
crudini --set "${DHCP_CONF}" DEFAULT enable_isolated_metadata "true"

# -----------------------------------------------------------------------------
# Step 9: Configure Metadata agent
# -----------------------------------------------------------------------------
# The metadata agent provides config-drive/cloud-init data to VMs.
# VMs access http://169.254.169.254 which the metadata agent intercepts.
echo ">>> Step 9: Configuring Metadata agent..."

META_CONF="/etc/neutron/metadata_agent.ini"
crudini --set "${META_CONF}" DEFAULT nova_metadata_host "${CONTROLLER}"
crudini --set "${META_CONF}" DEFAULT metadata_proxy_shared_secret "${METADATA_SECRET}"

# -----------------------------------------------------------------------------
# Step 10: Configure Nova to use Neutron
# -----------------------------------------------------------------------------
# Nova needs to know about Neutron for networking during instance boot.
echo ">>> Step 10: Configuring Nova to use Neutron..."

NOVA_CONF="/etc/nova/nova.conf"
crudini --set "${NOVA_CONF}" neutron auth_url "http://${CONTROLLER}:5000/v3"
crudini --set "${NOVA_CONF}" neutron auth_type "password"
crudini --set "${NOVA_CONF}" neutron project_domain_name "Default"
crudini --set "${NOVA_CONF}" neutron user_domain_name "Default"
crudini --set "${NOVA_CONF}" neutron region_name "${REGION}"
crudini --set "${NOVA_CONF}" neutron project_name "service"
crudini --set "${NOVA_CONF}" neutron username "neutron"
crudini --set "${NOVA_CONF}" neutron password "${NEUTRON_PASS}"
crudini --set "${NOVA_CONF}" neutron service_metadata_proxy "true"
crudini --set "${NOVA_CONF}" neutron metadata_proxy_shared_secret "${METADATA_SECRET}"

# -----------------------------------------------------------------------------
# Step 11: Sync database
# -----------------------------------------------------------------------------
echo ">>> Step 11: Syncing Neutron database..."
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
    --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron

# -----------------------------------------------------------------------------
# Step 12: Start services
# -----------------------------------------------------------------------------
echo ">>> Step 12: Starting Neutron services..."

# Restart Nova API (picks up neutron config)
systemctl restart nova-api

for SVC in neutron-server neutron-linuxbridge-agent neutron-dhcp-agent \
    neutron-metadata-agent neutron-l3-agent; do
    systemctl enable --now "${SVC}"
    systemctl restart "${SVC}"
done

sleep 3

# -----------------------------------------------------------------------------
# Step 13: Verify
# -----------------------------------------------------------------------------
echo ">>> Step 13: Verifying Neutron..."
echo "  Network agents:"
openstack network agent list

if openstack network agent list | grep -q "alive"; then
    echo ""
    echo "    ✓ Neutron operational — agents running."
else
    echo ""
    echo "    ✗ WARNING: No agents showing. Check neutron-server logs."
fi

# -----------------------------------------------------------------------------
# Step 14: Fix network route conflicts
# -----------------------------------------------------------------------------
# After Neutron creates bridges, they sometimes inherit the host's IP address,
# causing routing conflicts where traffic goes to dead bridges instead of the
# real network interface. This function detects and fixes such conflicts.
echo ">>> Step 14: Checking for network route conflicts..."

fix_network_routes() {
    local TEST_HOST="1.1.1.1"
    local REAL_IFACE="${PROVIDER_INTERFACE}"
    
    echo "  Checking routing for ${TEST_HOST} via ${REAL_IFACE}..."
    
    # Get current route
    local ROUTE_LINE
    ROUTE_LINE=$(ip route get "${TEST_HOST}" 2>/dev/null || true)
    if [[ -z "${ROUTE_LINE}" ]]; then
        echo "  WARNING: No route to ${TEST_HOST} (network may be unreachable)"
        return 1
    fi
    
    local ROUTE_IFACE
    ROUTE_IFACE=$(echo "${ROUTE_LINE}" | grep -oP 'dev \K\S+')
    echo "  Current route: ${ROUTE_LINE}"
    
    # Get real interface details
    local REAL_INFO REAL_STATE REAL_IP REAL_IP_ADDR
    REAL_INFO=$(ip addr show "${REAL_IFACE}" 2>/dev/null || true)
    if [[ -z "${REAL_INFO}" ]]; then
        echo "  ERROR: Interface ${REAL_IFACE} not found"
        return 1
    fi
    
    REAL_STATE=$(echo "${REAL_INFO}" | head -1 | grep -oP 'state \K\S+')
    REAL_IP=$(echo "${REAL_INFO}" | grep -oP 'inet \K[0-9.]+/[0-9]+' | head -1 || true)
    
    if [[ -z "${REAL_IP}" ]]; then
        echo "  ERROR: ${REAL_IFACE} has no IPv4 address"
        return 1
    fi
    
    REAL_IP_ADDR="${REAL_IP%%/*}"
    echo "  Real interface ${REAL_IFACE}: state=${REAL_STATE}, ip=${REAL_IP}"
    
    # Find conflicting interfaces (typically brq* bridges)
    local CONFLICT_IFACE="" CONFLICT_STATE
    while read -r ifname; do
        [[ "${ifname}" == "${REAL_IFACE}" ]] && continue
        # Only check bridge interfaces that could conflict
        [[ "${ifname}" =~ ^br ]] || continue
        
        local IFACE_INFO
        IFACE_INFO=$(ip addr show "${ifname}" 2>/dev/null || true)
        if echo "${IFACE_INFO}" | grep -q "inet ${REAL_IP_ADDR}/"; then
            CONFLICT_IFACE="${ifname}"
            CONFLICT_STATE=$(echo "${IFACE_INFO}" | head -1 | grep -oP 'state \K\S+')
            break
        fi
    done < <(ip -o link show | awk -F': ' '{print $2}')
    
    # Check if fix is needed
    local NEEDS_FIX=false
    if [[ -n "${CONFLICT_IFACE}" ]]; then
        echo "  CONFLICT: ${CONFLICT_IFACE} (state=${CONFLICT_STATE}) also holds ${REAL_IP_ADDR}"
        NEEDS_FIX=true
    fi
    
    if [[ "${ROUTE_IFACE}" != "${REAL_IFACE}" ]]; then
        echo "  ISSUE: Default route using ${ROUTE_IFACE} instead of ${REAL_IFACE}"
        NEEDS_FIX=true
    fi
    
    if [[ "${NEEDS_FIX}" == "false" ]]; then
        echo "  ✓ No routing conflicts detected"
        return 0
    fi
    
    echo "  Applying network route fix..."
    
    # Remove duplicate IP from conflicting bridge
    if [[ -n "${CONFLICT_IFACE}" ]]; then
        echo "    Removing ${REAL_IP} from ${CONFLICT_IFACE}..."
        ip addr del "${REAL_IP}" dev "${CONFLICT_IFACE}" 2>/dev/null || true
    fi
    
    # Ensure proper routes exist
    local REAL_IP_PREFIX="${REAL_IP##*/}"
    local SUBNET="${REAL_IP_ADDR%.*}.0/${REAL_IP_PREFIX}"
    
    # Re-add subnet route if missing
    if ! ip route show "${SUBNET}" 2>/dev/null | grep -q "dev ${REAL_IFACE}"; then
        echo "    Re-adding subnet route ${SUBNET} dev ${REAL_IFACE}..."
        ip route add "${SUBNET}" dev "${REAL_IFACE}" src "${REAL_IP_ADDR}" 2>/dev/null || true
    fi
    
    # Re-add default route if needed
    if ! ip route show default 2>/dev/null | grep -q "dev ${REAL_IFACE}"; then
        # Try to find existing gateway
        local GW
        GW=$(ip route show | grep "^default" | grep -oP 'via \K\S+' | head -1 || true)
        if [[ -z "${GW}" ]]; then
            # Fallback: assume .1 is gateway
            GW="${REAL_IP_ADDR%.*}.1"
        fi
        echo "    Re-adding default route via ${GW} dev ${REAL_IFACE}..."
        ip route add default via "${GW}" dev "${REAL_IFACE}" 2>/dev/null || true
    fi
    
    echo "  ✓ Network routes fixed"
    
    # Verify fix
    local NEW_ROUTE
    NEW_ROUTE=$(ip route get "${TEST_HOST}" 2>/dev/null || true)
    echo "  Verified route: ${NEW_ROUTE}"
}

# Run the network fix function
fix_network_routes || echo "  Warning: Could not fix network routes automatically"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Neutron Installation Complete ==="
echo ""
echo "  Endpoint:           http://${CONTROLLER}:9696"
echo "  Provider interface: ${PROVIDER_INTERFACE}"
echo "  Tenant network:     VXLAN (VNI 1-1000)"
echo ""
echo "Next: Run 07-cinder.sh to install block storage."
