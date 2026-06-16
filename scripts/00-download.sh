#!/usr/bin/env bash
# =============================================================================
# 00-download.sh — Air-Gap Package Download
# =============================================================================
# This script downloads every .deb package and dependency required to install
# OpenStack Caracal (2024.1) on Ubuntu 24.04. Run this while you have internet.
# After completion, all subsequent install scripts work entirely offline.
#
# What it does:
#   1. Adds the Ubuntu Cloud Archive (Caracal) repository
#   2. Downloads (but does not install) all OpenStack packages + dependencies
#   3. Creates a local apt repository from the downloaded .debs
#   4. Stores everything under /opt/openstack-airgap/
#
# Usage:
#   sudo bash 00-download.sh
#
# Re-run safe: Yes — re-downloads only missing/updated packages
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
AIRGAP_DIR="/opt/openstack-airgap"
DEB_DIR="${AIRGAP_DIR}/debs"
REPO_DIR="${AIRGAP_DIR}/repo"
IMAGES_DIR="${AIRGAP_DIR}/images"

# All packages we need across all services
PACKAGES=(
    # Base infrastructure
    mariadb-server python3-pymysql
    rabbitmq-server
    memcached python3-memcache
    # Keystone
    keystone python3-openstackclient apache2 libapache2-mod-wsgi-py3
    # Glance
    glance
    # Placement
    placement-api
    # Nova (controller + compute on same node)
    nova-api nova-conductor nova-novncproxy nova-scheduler
    nova-compute
    # Neutron (LinuxBridge self-service networking)
    neutron-server neutron-plugin-ml2
    neutron-linuxbridge-agent neutron-l3-agent neutron-dhcp-agent neutron-metadata-agent
    # OVN (alternative to LinuxBridge - for migration script)
    ovn-central ovn-host ovn-common neutron-ovn-metadata-agent
    openvswitch-switch openvswitch-common python3-openvswitch
    # Cinder (LVM backend)
    cinder-api cinder-scheduler cinder-volume
    lvm2 thin-provisioning-tools tgt
    # Horizon
    openstack-dashboard
    # Heat (orchestration)
    heat-api heat-api-cfn heat-engine python3-heatclient
    python3-heat-dashboard heat-dashboard-common
    # Octavia (load balancing)
    octavia-api octavia-health-manager octavia-housekeeping octavia-worker python3-octaviaclient
    octavia-dashboard diskimage-builder debootstrap qemu-utils
    # Supporting tools
    python3-openstackclient python3-osc-placement
    bridge-utils ebtables ipset conntrack
    dpkg-dev apt-utils crudini
    # Virtualisation (KVM/QEMU for Nova compute)
    qemu-kvm libvirt-daemon-system libvirt-clients virtinst
)

# =============================================================================
# Pre-flight checks
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)." >&2
    exit 1
fi

echo "=== OpenStack Air-Gap Download Script ==="
echo "Target directory: ${AIRGAP_DIR}"
echo ""

# -----------------------------------------------------------------------------
# Step 1: Update package index
# -----------------------------------------------------------------------------
# Ubuntu 24.04 (Noble) ships OpenStack Caracal (2024.1) in its own repos.
# No cloud-archive PPA needed — unlike 22.04 where you'd add it manually.
echo ">>> Step 1: Updating package index..."
apt-get update -qq
echo "    Package index updated (Noble includes Caracal natively)."

# -----------------------------------------------------------------------------
# Step 2: Create download directories
# -----------------------------------------------------------------------------
echo ">>> Step 2: Creating directories..."
mkdir -p "${DEB_DIR}" "${REPO_DIR}" "${IMAGES_DIR}"

# -----------------------------------------------------------------------------
# Step 3: Download all packages and their dependencies
# -----------------------------------------------------------------------------
echo ">>> Step 3: Downloading packages (this may take a while)..."
echo "    Packages to resolve: ${#PACKAGES[@]}"

# Download packages into DEB_DIR without installing
# apt-get download only fetches the named package, not deps.
# We use a cleaner approach: download to cache then copy.
apt-get install --download-only --allow-downgrades -y "${PACKAGES[@]}" 2>&1 | tail -5

echo "    Copying cached .debs to ${DEB_DIR}..."
cp -u /var/cache/apt/archives/*.deb "${DEB_DIR}/" 2>/dev/null || true

DEB_COUNT=$(find "${DEB_DIR}" -name "*.deb" | wc -l)
echo "    Downloaded ${DEB_COUNT} packages."

# -----------------------------------------------------------------------------
# Step 4: Build local apt repository
# -----------------------------------------------------------------------------
echo ">>> Step 4: Building local apt repository..."

cd "${REPO_DIR}"
# Link debs into repo dir
ln -sf "${DEB_DIR}"/*.deb . 2>/dev/null || cp -u "${DEB_DIR}"/*.deb . 2>/dev/null || true

# Generate Packages index
dpkg-scanpackages --multiversion . /dev/null 2>/dev/null | gzip -9c > Packages.gz
dpkg-scanpackages --multiversion . /dev/null 2>/dev/null > Packages

echo "    Local repository built at ${REPO_DIR}"

OFFLINE_SOURCE="${AIRGAP_DIR}/openstack-offline.list"
cat > "${OFFLINE_SOURCE}" <<EOF
# OpenStack Air-Gap Local Repository
# Copy this to /etc/apt/sources.list.d/ to enable offline installs
deb [trusted=yes] file://${REPO_DIR} ./
EOF

echo "    Offline source list: ${OFFLINE_SOURCE}"

# -----------------------------------------------------------------------------
# Step 5: Download a test image (CirrOS — tiny cloud image for testing)
# -----------------------------------------------------------------------------
echo ">>> Step 5: Downloading CirrOS test image..."
CIRROS_VERSION="0.6.2"
CIRROS_URL="https://download.cirros-cloud.net/${CIRROS_VERSION}/cirros-${CIRROS_VERSION}-x86_64-disk.img"
CIRROS_FILE="${IMAGES_DIR}/cirros-${CIRROS_VERSION}-x86_64-disk.img"

if [[ ! -f "${CIRROS_FILE}" ]]; then
    wget -q --show-progress -O "${CIRROS_FILE}" "${CIRROS_URL}"
    echo "    CirrOS ${CIRROS_VERSION} downloaded."
else
    echo "    CirrOS ${CIRROS_VERSION} already present."
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Download Complete ==="
echo "  Packages:    ${DEB_COUNT} .deb files in ${DEB_DIR}"
echo "  Repository:  ${REPO_DIR}"
echo "  Images:      ${IMAGES_DIR}"
echo "  Total size:  $(du -sh "${AIRGAP_DIR}" | cut -f1)"
echo ""
echo "You can now disconnect from the internet."
echo "Run 01-base.sh to begin installation."
