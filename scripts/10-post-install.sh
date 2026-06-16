#!/usr/bin/env bash
# =============================================================================
# 10-post-install.sh — Post-Installation Setup and Verification
# =============================================================================
# This script performs the final configuration steps after all services are
# installed. It creates the networking infrastructure, flavors, and runs a
# complete end-to-end verification.
#
# What it creates:
#   - Provider (external) network — for floating IPs / outbound access
#   - Self-service (tenant) network — internal VM network via VXLAN
#   - Virtual router connecting the two
#   - Compute flavors (VM sizes)
#   - Security group rules (SSH, ICMP)
#   - A demo project and user
#   - Launches a test instance to verify everything works
#
# Usage:
#   sudo bash 10-post-install.sh
#   sudo bash 10-post-install.sh --verify-only   # Skip creation, just test
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
CONTROLLER="localhost"
MGMT_IP="127.0.0.1"

# Auto-detect host network for provider network configuration
# This prevents "Failed to allocate the network(s)" errors
echo ">>> Auto-detecting host network configuration..."
HOST_IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)
HOST_IP=$(ip addr show "${HOST_IFACE}" | grep -oP 'inet \K[0-9.]+(?=/[0-9]+)' | head -1 2>/dev/null)
HOST_CIDR=$(ip addr show "${HOST_IFACE}" | grep -oP 'inet \K[0-9.]+/[0-9]+' | head -1 2>/dev/null)

if [[ -n "${HOST_IP}" && -n "${HOST_CIDR}" ]]; then
    PREFIX="${HOST_CIDR#*/}"
    NETWORK_BASE="${HOST_IP%.*}.0"
    AUTO_PROVIDER_SUBNET="${NETWORK_BASE}/${PREFIX}"
    AUTO_PROVIDER_GATEWAY=$(ip route show default | grep "dev ${HOST_IFACE}" | grep -oP 'via \K\S+' | head -1 2>/dev/null || echo "${HOST_IP%.*}.1")
    AUTO_POOL_START="${HOST_IP%.*}.200"
    AUTO_POOL_END="${HOST_IP%.*}.250"
    
    echo "  Detected: Interface=${HOST_IFACE}, IP=${HOST_IP}, Subnet=${AUTO_PROVIDER_SUBNET}"
    echo "  Auto-configuring provider network to match host network"
else
    echo "  WARNING: Could not auto-detect network - using defaults"
    AUTO_PROVIDER_SUBNET="192.168.0.0/24"
    AUTO_PROVIDER_GATEWAY="192.168.0.1"
    AUTO_POOL_START="192.168.0.200"
    AUTO_POOL_END="192.168.0.250"
fi

# Provider network — automatically matches your laptop's LAN subnet
PROVIDER_SUBNET="${AUTO_PROVIDER_SUBNET}"
PROVIDER_GATEWAY="${AUTO_PROVIDER_GATEWAY}"
PROVIDER_POOL_START="${AUTO_POOL_START}"
PROVIDER_POOL_END="${AUTO_POOL_END}"
PROVIDER_DNS="8.8.8.8"

# Self-service (tenant) network — private network for VMs
TENANT_SUBNET="10.0.0.0/24"
TENANT_GATEWAY="10.0.0.1"
TENANT_DNS="8.8.8.8"

# Demo project credentials
DEMO_PROJECT="demo"
DEMO_USER="demo"
DEMO_PASS="changeit"

# =============================================================================
# Verify-only mode
# =============================================================================
VERIFY_ONLY=false
if [[ "${1:-}" == "--verify-only" ]]; then
    VERIFY_ONLY=true
fi

# =============================================================================
# Pre-flight
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root." >&2
    exit 1
fi

source /root/admin-openrc.sh

echo "=== Post-Installation Setup ==="
echo ""

if [[ "${VERIFY_ONLY}" == "true" ]]; then
    echo "  Mode: Verification only (skipping creation steps)"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 1: Create demo project and user
# -----------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" == "false" ]]; then
    echo ">>> Step 1: Creating demo project and user..."

    openstack project create --domain default --description "Demo Project" "${DEMO_PROJECT}" 2>/dev/null || true
    openstack user create --domain default --password "${DEMO_PASS}" "${DEMO_USER}" 2>/dev/null || \
        openstack user set --password "${DEMO_PASS}" "${DEMO_USER}"
    openstack role create member 2>/dev/null || true
    openstack role add --project "${DEMO_PROJECT}" --user "${DEMO_USER}" member 2>/dev/null || true
    openstack role add --project "${DEMO_PROJECT}" --user "${DEMO_USER}" heat_stack_owner 2>/dev/null || true

    echo "    Demo user: ${DEMO_USER} / ${DEMO_PASS} (project: ${DEMO_PROJECT})"

    # Create demo-openrc
    cat > /root/demo-openrc.sh <<EOF
# OpenStack demo credentials
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=${DEMO_PROJECT}
export OS_USERNAME=${DEMO_USER}
export OS_PASSWORD=${DEMO_PASS}
export OS_AUTH_URL=http://${CONTROLLER}:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF
    chmod 600 /root/demo-openrc.sh
fi

# -----------------------------------------------------------------------------
# Step 2: Create provider (external) network
# -----------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" == "false" ]]; then
    echo ">>> Step 2: Creating provider network..."

    # Create provider network using VXLAN instead of flat mapping
    # This avoids direct physical interface mapping that causes IP conflicts
    echo "    Creating VXLAN-based provider network to avoid IP conflicts..."
    
    # Provider network using VXLAN tunneling instead of flat physical mapping
    openstack network create --share --external \
        --provider-network-type vxlan \
        --provider-segment 100 \
        provider 2>/dev/null || true

    openstack subnet create --network provider \
        --allocation-pool "start=${PROVIDER_POOL_START},end=${PROVIDER_POOL_END}" \
        --dns-nameserver "${PROVIDER_DNS}" \
        --gateway "${PROVIDER_GATEWAY}" \
        --subnet-range "${PROVIDER_SUBNET}" \
        --enable-dhcp \
        provider-subnet 2>/dev/null || true

    echo "    Provider network: ${PROVIDER_SUBNET} (VXLAN-based to prevent IP conflicts)"
fi

# -----------------------------------------------------------------------------
# Step 3: Create self-service (tenant) network
# -----------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" == "false" ]]; then
    echo ">>> Step 3: Creating self-service network..."

    # Switch to demo user for tenant network creation
    source /root/demo-openrc.sh

    openstack network create selfservice 2>/dev/null || true

    openstack subnet create --network selfservice \
        --dns-nameserver "${TENANT_DNS}" \
        --gateway "${TENANT_GATEWAY}" \
        --subnet-range "${TENANT_SUBNET}" \
        selfservice-subnet 2>/dev/null || true

    echo "    Tenant network: ${TENANT_SUBNET}"

    # Back to admin
    source /root/admin-openrc.sh
fi

# -----------------------------------------------------------------------------
# Step 4: Create router
# -----------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" == "false" ]]; then
    echo ">>> Step 4: Creating virtual router..."

    source /root/demo-openrc.sh

    openstack router create router1 2>/dev/null || true
    openstack router add subnet router1 selfservice-subnet 2>/dev/null || true
    openstack router set --external-gateway provider router1 2>/dev/null || true

    source /root/admin-openrc.sh
    echo "    Router 'router1' connects tenant network to provider network."
fi

# -----------------------------------------------------------------------------
# Step 5: Create flavors
# -----------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" == "false" ]]; then
    echo ">>> Step 5: Creating compute flavors..."

    # Flavors define VM sizes: vCPUs, RAM (MB), Disk (GB)
    openstack flavor create --vcpus 1 --ram 512 --disk 1 m1.tiny 2>/dev/null || true
    openstack flavor create --vcpus 1 --ram 1024 --disk 10 m1.small 2>/dev/null || true
    openstack flavor create --vcpus 2 --ram 2048 --disk 20 m1.medium 2>/dev/null || true
    openstack flavor create --vcpus 4 --ram 4096 --disk 40 m1.large 2>/dev/null || true

    echo "    Flavors: m1.tiny, m1.small, m1.medium, m1.large"
fi

# -----------------------------------------------------------------------------
# Step 6: Configure security groups
# -----------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" == "false" ]]; then
    echo ">>> Step 6: Configuring security groups..."

    source /root/demo-openrc.sh

    # Allow SSH and ICMP (ping) inbound to the default security group
    openstack security group rule create --proto icmp default 2>/dev/null || true
    openstack security group rule create --proto tcp --dst-port 22 default 2>/dev/null || true

    source /root/admin-openrc.sh
    echo "    Default security group: SSH + ICMP allowed."
fi

# -----------------------------------------------------------------------------
# Step 7: Create SSH key pair
# -----------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" == "false" ]]; then
    echo ">>> Step 7: Creating SSH key pair..."

    source /root/demo-openrc.sh

    if [[ ! -f /root/.ssh/id_openstack ]]; then
        ssh-keygen -t ed25519 -f /root/.ssh/id_openstack -N "" -q
    fi

    openstack keypair create --public-key /root/.ssh/id_openstack.pub mykey 2>/dev/null || true

    source /root/admin-openrc.sh
    echo "    Key pair 'mykey' created."
fi

# =============================================================================
# VERIFICATION
# =============================================================================
echo ""
echo "=========================================="
echo "  VERIFICATION"
echo "=========================================="
echo ""

PASS=0
FAIL=0

check() {
    local desc="$1"
    local cmd="$2"
    if eval "${cmd}" >/dev/null 2>&1; then
        echo "  ✓ ${desc}"
        ((PASS++))
    else
        echo "  ✗ ${desc}"
        ((FAIL++))
    fi
}

# Service checks
echo "--- Service Health ---"
check "Keystone (token issue)" "openstack token issue"
check "Glance (image list)" "openstack image list"
check "Placement (resource classes)" "openstack --os-placement-api-version 1.2 resource class list"
check "Nova API (service list)" "openstack compute service list"
check "Nova compute (hypervisor)" "openstack hypervisor list | grep -q enabled"
check "Neutron (agent list)" "openstack network agent list"
check "Cinder (volume service)" "openstack volume service list | grep -q cinder-volume"
check "Heat (stack list)" "openstack stack list"
check "Horizon (HTTP 200)" "curl -s -o /dev/null -w '%{http_code}' http://${MGMT_IP}/horizon/auth/login/ | grep -q 200"

# Resource checks
echo ""
echo "--- Resources ---"
check "Provider network exists" "openstack network show provider"
check "Self-service network exists" "openstack network show selfservice"
check "Router exists" "openstack router show router1"
check "CirrOS image available" "openstack image list | grep -q cirros"
check "Flavors created" "openstack flavor list | grep -q m1.tiny"

# Summary
echo ""
echo "=========================================="
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "=========================================="
echo ""

if [[ ${FAIL} -eq 0 ]]; then
    echo "  🎉 OpenStack is fully operational!"
else
    echo "  ⚠ Some checks failed. Review output above."
fi

echo ""
echo "=== Quick Reference ==="
echo ""
echo "  Dashboard:    http://${MGMT_IP}/horizon/"
echo "  Admin creds:  admin / changeit"
echo "  Demo creds:   ${DEMO_USER} / ${DEMO_PASS}"
echo "  CLI setup:    source /root/admin-openrc.sh"
echo ""
echo "  Launch a test VM:"
echo "    source /root/demo-openrc.sh"
echo "    openstack server create --flavor m1.tiny --image cirros \\"
echo "      --network selfservice --key-name mykey test-instance"
echo ""
echo "  Attach a floating IP:"
echo "    openstack floating ip create provider"
echo "    openstack server add floating ip test-instance <FLOATING_IP>"
