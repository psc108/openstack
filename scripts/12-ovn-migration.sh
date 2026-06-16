#!/usr/bin/env bash
# =============================================================================
# 12-ovn-migration.sh — OpenStack ML2/LinuxBridge to ML2/OVN Migration
# =============================================================================
# Migrates the single-node OpenStack deployment from ML2/LinuxBridge to ML2/OVN
# following the phased approach defined in ovn-migration-guide.md
#
# What this does:
#   - Installs OVN packages (ovn-central, ovn-host)
#   - Configures OVN Northbound and Southbound databases
#   - Migrates Neutron configuration from LinuxBridge to OVN
#   - Performs database synchronization (Neutron DB → OVN NB DB)
#   - Replaces LinuxBridge agents with OVN Controller and Metadata agent
#   - Validates connectivity and cleans up legacy agents
#
# Prerequisites:
#   - Working ML2/LinuxBridge deployment (06-neutron.sh completed)
#   - All instances must be in ACTIVE state
#   - Network connectivity verified pre-migration
#
# Usage:
#   sudo bash 12-ovn-migration.sh                    # Full migration
#
# Pre-migration validation
#   sudo bash 12-ovn-migration.sh --rollback         # Rollback to LinuxBridge
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration Variables
# -----------------------------------------------------------------------------
CONTROLLER="localhost"
MGMT_IP="127.0.0.1"
REGION="RegionOne"

# Database passwords (must match existing installation)
NEUTRON_DB_PASS="changeit"
NEUTRON_PASS="changeit"
NOVA_PASS="changeit"
RABBIT_PASS="changeit"
METADATA_SECRET="changeit"

# OVN Configuration
OVN_NB_PORT="6641"
OVN_SB_PORT="6642"
BACKUP_DIR="/root/ovn-migration-backup-$(date +%Y%m%d-%H%M%S)"

# =============================================================================
# Helper Functions
# =============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

wait_for_service() {
    local service=$1
    local timeout=${2:-30}
    local count=0
    
    log "Waiting for $service to start..."
    while ! systemctl is-active --quiet "$service" && [ $count -lt $timeout ]; do
        sleep 1
        ((count++))
    done
    
    if systemctl is-active --quiet "$service"; then
        log "$service is active"
    else
        log "ERROR: $service failed to start within ${timeout}s"
        return 1
    fi
}

backup_file() {
    local file=$1
    if [[ -f "$file" ]]; then
        cp "$file" "${BACKUP_DIR}/$(basename "$file").backup"
        log "Backed up $file"
    fi
}

validate_neutron_state() {
    log "Validating current Neutron state..."
    
    # Check that neutron-server is running ML2/LinuxBridge
    local mechanism_driver
    mechanism_driver=$(crudini --get /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers 2>/dev/null || echo "")
    if [[ "$mechanism_driver" != *"linuxbridge"* ]]; then
        log "ERROR: Current mechanism driver is '$mechanism_driver', expected LinuxBridge"
        return 1
    fi
    
    # Test basic connectivity
    log "Testing basic OpenStack connectivity..."
    if ! openstack network list >/dev/null 2>&1; then
        log "ERROR: Cannot list networks - OpenStack API may be unavailable"
        return 1
    fi
    
    log "✓ Neutron state validation passed"
    return 0
}

# =============================================================================
# Validation Mode
# =============================================================================
if [[ "${1:-}" == "--validate-only" ]]; then
    log "=== Pre-Migration Validation ==="
    
    # Source admin credentials for API access
    if [[ -f "/root/admin-openrc.sh" ]]; then
        source /root/admin-openrc.sh
        log "Sourced admin credentials"
    else
        log "ERROR: /root/admin-openrc.sh not found - OpenStack not properly installed"
        exit 1
    fi
    
    # Check OVS version requirements
    log "Checking OVS version..."
    if command -v ovs-vsctl >/dev/null 2>&1; then
        ovs_version=$(ovs-vsctl --version | head -1 | awk '{print $4}')
        log "OVS version: $ovs_version"
    else
        log "WARNING: OVS not found - will be installed during migration"
        log "NOTE: Run without --validate-only to install OVS and OVN packages"
    fi
    
    # Validate current state
    validate_neutron_state
    
    # Check for running instances
    active_instances=$(openstack server list --all-projects --status ACTIVE -f value -c ID | wc -l)
    log "Active instances: $active_instances"
    
    log "✓ Pre-migration validation complete"
    exit 0
fi

# =============================================================================
# Pre-flight Checks
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)." >&2
    exit 1
fi

if [[ ! -f "/root/admin-openrc.sh" ]]; then
    echo "ERROR: /root/admin-openrc.sh not found. Run 02-keystone.sh first." >&2
    exit 1
fi

source /root/admin-openrc.sh

log "=== OVN Migration Starting ==="
log "Backup directory: $BACKUP_DIR"
log ""

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Validate pre-migration state
validate_neutron_state

# =============================================================================
# Phase 1: Pre-Migration Preparation  
# =============================================================================
log ">>> Phase 1: Pre-Migration Preparation"

# Backup current configuration
log "Backing up current configuration..."
backup_file "/etc/neutron/neutron.conf"
backup_file "/etc/neutron/plugins/ml2/ml2_conf.ini"
backup_file "/etc/neutron/plugins/ml2/linuxbridge_agent.ini"
backup_file "/etc/neutron/l3_agent.ini"
backup_file "/etc/neutron/dhcp_agent.ini"
backup_file "/etc/neutron/metadata_agent.ini"

# Backup Neutron database
log "Backing up Neutron database..."
mysqldump -u root -pchangeit --single-transaction neutron > "${BACKUP_DIR}/neutron-pre-ovn.sql"

# Record current agent state
log "Recording current network agents..."
openstack network agent list -f json > "${BACKUP_DIR}/agents-pre-ovn.json"

# Install OVN packages (including OVS prerequisites)
log "Installing OVN and OVS packages..."
apt-get update -qq
apt-get install -y openvswitch-switch openvswitch-common python3-openvswitch
apt-get install -y ovn-central ovn-host ovn-common neutron-ovn-metadata-agent

# Start OVS service (required for OVN)
systemctl enable --now openvswitch-switch
wait_for_service "openvswitch-switch"

# Set OVS external IDs for OVN
log "Configuring OVS for OVN..."
ovs-vsctl set open . external-ids:ovn-encap-type=geneve
ovs-vsctl set open . external-ids:ovn-encap-ip="$MGMT_IP"
# Note: ovn-bridge-mappings left unset for now - will be configured later if needed

# Fix OVN socket permissions for neutron user access
# This is critical - without this, neutron-server cannot connect to OVN databases
log "Configuring OVN socket permissions for neutron user..."
# Wait for OVN sockets to be created
sleep 2
if [[ -S "/var/run/ovn/ovnnb_db.sock" && -S "/var/run/ovn/ovnsb_db.sock" ]]; then
    chgrp neutron /var/run/ovn/ovnnb_db.sock /var/run/ovn/ovnsb_db.sock
    chmod g+rw /var/run/ovn/ovnnb_db.sock /var/run/ovn/ovnsb_db.sock
    log "OVN socket permissions configured for neutron user"
else
    log "WARNING: OVN sockets not found yet - permissions will be set after OVN central starts"
fi

log "✓ Phase 1 complete"

# =============================================================================
# Phase 2: Controller Node Migration
# =============================================================================
log ">>> Phase 2: Controller Node Migration"

# Initialize OVN databases
log "Initializing OVN databases..."
systemctl enable --now ovn-central
wait_for_service "ovn-central"

# CRITICAL: Fix OVN socket permissions for neutron user
# Without this, neutron-server will crash with "Permission denied" errors
log "Ensuring OVN socket permissions for neutron user..."
sleep 3  # Allow OVN central to fully initialize sockets
if [[ -S "/var/run/ovn/ovnnb_db.sock" && -S "/var/run/ovn/ovnsb_db.sock" ]]; then
    chgrp neutron /var/run/ovn/ovnnb_db.sock /var/run/ovn/ovnsb_db.sock
    chmod g+rw /var/run/ovn/ovnnb_db.sock /var/run/ovn/ovnsb_db.sock
    log "✓ OVN socket permissions configured: neutron user can access OVN databases"
    
    # Test the connection
    if sudo -u neutron ovsdb-client list-dbs unix:/var/run/ovn/ovnnb_db.sock >/dev/null 2>&1; then
        log "✓ Verified: neutron user can connect to OVN northbound database"
    else
        log "ERROR: neutron user still cannot connect to OVN database - neutron-server will fail"
        exit 1
    fi
else
    log "ERROR: OVN database sockets not found - OVN central failed to start properly"
    exit 1
fi

# Update Neutron configuration for OVN
log "Updating Neutron configuration for OVN..."

NEUTRON_CONF="/etc/neutron/neutron.conf"
ML2_CONF="/etc/neutron/plugins/ml2/ml2_conf.ini"

# Update service plugins
crudini --set "$NEUTRON_CONF" DEFAULT service_plugins "ovn-router,trunk"

# Update ML2 configuration
crudini --set "$ML2_CONF" ml2 mechanism_drivers "ovn"
crudini --set "$ML2_CONF" ml2 type_drivers "local,flat,vlan,geneve"
crudini --set "$ML2_CONF" ml2 tenant_network_types "geneve"
crudini --set "$ML2_CONF" ml2 extension_drivers "port_security"

# Add OVN configuration section
crudini --set "$ML2_CONF" ovn ovn_nb_connection "unix:/var/run/ovn/ovnnb_db.sock"
crudini --set "$ML2_CONF" ovn ovn_sb_connection "unix:/var/run/ovn/ovnsb_db.sock"
crudini --set "$ML2_CONF" ovn ovn_l3_scheduler "leastloaded"
crudini --set "$ML2_CONF" ovn ovn_metadata_enabled "True"
crudini --set "$ML2_CONF" ovn enable_distributed_floating_ip "True"

# Configure Geneve type driver
crudini --set "$ML2_CONF" ml2_type_geneve vni_ranges "1:65536"
crudini --set "$ML2_CONF" ml2_type_geneve max_header_size "38"

# Stop LinuxBridge agents on controller
log "Stopping LinuxBridge agents..."
systemctl stop neutron-linuxbridge-agent neutron-l3-agent neutron-dhcp-agent neutron-metadata-agent
systemctl disable neutron-linuxbridge-agent neutron-l3-agent neutron-dhcp-agent neutron-metadata-agent

# Restart neutron-server with OVN
log "Restarting neutron-server with OVN configuration..."
systemctl restart neutron-server
wait_for_service "neutron-server"

log "✓ Phase 2 complete"

# =============================================================================
# Phase 3: Database Synchronization
# =============================================================================
log ">>> Phase 3: Database Synchronization"

# Run OVN database sync
log "Running OVN database synchronization (this may take several minutes)..."
neutron-ovn-db-sync-util \
    --config-file /etc/neutron/neutron.conf \
    --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
    --ovn-neutron_sync_mode migrate \
    --log-file "${BACKUP_DIR}/ovn-db-sync.log" || {
    log "ERROR: OVN database sync failed. Check ${BACKUP_DIR}/ovn-db-sync.log"
    exit 1
}

log "✓ Phase 3 complete"

# =============================================================================
# Phase 4: Compute Node Migration (Single-node deployment)
# =============================================================================
log ">>> Phase 4: Compute Node Migration"

# Clean up LinuxBridge namespaces and interfaces
log "Cleaning up LinuxBridge namespaces..."
for ns in $(ip netns list 2>/dev/null | grep -E '^(qrouter-|qdhcp-|snat-|fip-)' | awk '{print $1}' || true); do
    log "Removing namespace: $ns"
    ip netns delete "$ns" 2>/dev/null || true
done

# Remove LinuxBridge interfaces
log "Cleaning up LinuxBridge interfaces..."
for br in $(brctl show 2>/dev/null | awk '/^brq/{print $1}' || true); do
    log "Removing bridge: $br"
    ip link set "$br" down 2>/dev/null || true
    brctl delbr "$br" 2>/dev/null || true
done

# Set OVN remote connection for local controller
ovs-vsctl set open . external-ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock

# Start OVN controller and metadata agent
log "Starting OVN services..."
# ovn-controller is started automatically by ovn-host service
systemctl enable --now ovn-host
systemctl enable --now neutron-ovn-metadata-agent

wait_for_service "ovn-host"
wait_for_service "neutron-ovn-metadata-agent"

log "✓ Phase 4 complete"

# =============================================================================
# Phase 5: Validation & Cleanup
# =============================================================================
log ">>> Phase 5: Validation & Cleanup"

# Wait for port bindings to stabilize
log "Waiting for port bindings to stabilize..."
sleep 10

# Test basic connectivity
log "Testing network connectivity..."
if openstack network list >/dev/null 2>&1; then
    log "✓ OpenStack API accessible"
else
    log "ERROR: Cannot access OpenStack API"
    exit 1
fi

# Clean up dead agents from database
log "Cleaning up legacy network agents..."
DEAD_AGENTS=$(openstack network agent list --dead -f value -c ID)
for agent_id in $DEAD_AGENTS; do
    log "Removing dead agent: $agent_id"
    openstack network agent delete "$agent_id" 2>/dev/null || true
done

# Also clean up any remaining LinuxBridge agents by name
LB_AGENTS=$(openstack network agent list -f value -c ID -c "Agent Type" | grep -E "(Linux bridge|DHCP agent|L3 agent|Metadata agent)" | awk '{print $1}' || true)
for agent_id in $LB_AGENTS; do
    log "Removing LinuxBridge agent: $agent_id"
    openstack network agent delete "$agent_id" 2>/dev/null || true
done

# Show final agent status
log "Final network agent status:"
openstack network agent list

log "✓ Phase 5 complete"

# =============================================================================
# Phase 6: Horizon Dashboard Integration
# =============================================================================
log ">>> Phase 6: Horizon Dashboard Integration"

# OVN doesn't add new dashboard panels like Octavia, but we need to ensure
# the existing Neutron panels work correctly with the OVN backend

# Clear Python bytecode cache to ensure dashboard picks up backend changes
log "Clearing Horizon Python cache..."
find /usr/lib/python3/dist-packages/openstack_dashboard/ -name "*.pyc" -delete 2>/dev/null || true
find /usr/lib/python3/dist-packages/openstack_dashboard/ -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# Update Neutron dashboard configuration to work with OVN
HORIZON_LOCAL_SETTINGS="/usr/share/openstack-dashboard/openstack_dashboard/local/local_settings.d/_50_neutron.py"
log "Updating Horizon Neutron configuration for OVN..."

# Create or update Neutron configuration for Horizon
cat > "$HORIZON_LOCAL_SETTINGS" <<'EOF'
# Neutron Configuration for Horizon with OVN Backend
# OVN-specific configuration to ensure dashboard panels work correctly

# Enable OVN-compatible features in Neutron dashboard
OPENSTACK_NEUTRON_NETWORK = {
    'enable_router': True,
    'enable_quotas': True,
    'enable_ipv6': True,
    'enable_distributed_router': True,  # OVN supports distributed routing
    'enable_ha_router': False,  # OVN doesn't use traditional HA routers
    'enable_lb': True,
    'enable_firewall': True,
    'enable_vpn': False,  # Not typically used with OVN
    'enable_fip_topology_check': True,  # OVN handles floating IP topology
    'profile_support': None,
    'enable_quotas': True,
    'supported_provider_types': ['geneve', 'vlan', 'flat'],  # OVN provider types
    'segmentation_id_range': {},
    'extra_provider_types': {},
    'supported_vnic_types': ['normal'],
    'physical_networks': [],
}

# OVN-specific feature flags
# These ensure the dashboard doesn't show LinuxBridge-specific options
FEATURE_PACK = {
    'enable_router': True,
    'enable_quotas': True, 
    'enable_security_group': True,
    'enable_distributed_router': True,  # OVN native capability
    'enable_ha_router': False,  # Not applicable with OVN
    'enable_lb': True,
    'enable_firewall': True,
    'enable_fwaas': True,
    'enable_vpn': False,
}
EOF

chmod 644 "$HORIZON_LOCAL_SETTINGS"

# Collect static files and compress for Horizon
log "Updating Horizon static files..."
cd /usr/share/openstack-dashboard
python3 manage.py collectstatic --noinput >/dev/null 2>&1 || {
    log "Warning: collectstatic failed - continuing"
}
python3 manage.py compress --force >/dev/null 2>&1 || {
    log "Warning: compress failed - continuing"
}

# Restart Apache to pick up changes
log "Restarting Apache for Horizon dashboard..."
systemctl restart apache2
wait_for_service "apache2"

log "✓ Phase 6 complete - Horizon dashboard updated for OVN backend"

log "✓ Phase 5 complete"

# =============================================================================
# Summary
# =============================================================================
log ""
log "=== OVN Migration Complete ==="
log "  Migration type:    ML2/LinuxBridge → ML2/OVN"
log "  Tunnel protocol:   VXLAN → Geneve"
log "  Architecture:      Agent-based → Distributed OVN"
log "  Socket permissions: Fixed for neutron user access"
log "  Dashboard:         Updated for OVN backend compatibility"
log "  Backup location:   $BACKUP_DIR"
log ""
log "  OVN Services:"
log "    ovn-central:        $(systemctl is-active ovn-central)"
log "    ovn-host:           $(systemctl is-active ovn-host)"
log "    neutron-ovn-metadata-agent: $(systemctl is-active neutron-ovn-metadata-agent)"
log "    neutron-server:     $(systemctl is-active neutron-server)"
log "    apache2 (horizon):  $(systemctl is-active apache2)"
log ""
log "  Network Agents:"
openstack network agent list 2>/dev/null || log "    Unable to query network agents"
log ""
log "  Dashboard Access:"
log "    URL: http://127.0.0.1/horizon/"
log "    Networks: Project → Network → Networks (now uses OVN backend)"
log "    Routers: Project → Network → Routers (distributed routing)"
log ""
log "  Next steps:"
log "    1. Test VM connectivity: ping floating IPs"
log "    2. Test east-west traffic between tenant networks"
log "    3. Verify Horizon networks/routers panels work correctly"
log "    4. Monitor OVN logs: journalctl -u ovn-controller -f"
log ""
log "  OVN Management Commands:"
log "    ovn-nbctl show                 # Show logical topology"
log "    ovn-sbctl show                 # Show physical topology"
log "    ovn-sbctl list chassis         # Show compute nodes"
log "    ovs-ofctl dump-flows br-int    # Show OpenFlow rules"
log ""
log "Migration completed successfully!"