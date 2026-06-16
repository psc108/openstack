#!/usr/bin/env bash
# =============================================================================
# 99-uninstall.sh — Complete OpenStack Removal
# =============================================================================
# Removes all OpenStack services, databases, configs, and supporting
# infrastructure. Returns the system to pre-install state.
#
# Usage:
#   sudo bash 99-uninstall.sh
#   sudo bash 99-uninstall.sh --keep-lvm   # Keep Cinder volume group
# =============================================================================
set -euo pipefail

CINDER_VG="cinder-volumes"
CINDER_DISK="/dev/sda1"
KEEP_LVM=false

if [[ "${1:-}" == "--keep-lvm" ]]; then
    KEEP_LVM=true
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root." >&2
    exit 1
fi

echo "=== Complete OpenStack Uninstall ==="
echo ""
echo "This will remove ALL OpenStack services and data."
echo "Press Ctrl+C within 5 seconds to abort..."
sleep 5
echo ""

# Stop everything
echo ">>> Stopping all OpenStack services..."
SERVICES=(
    heat-api heat-api-cfn heat-engine
    nova-api nova-scheduler nova-conductor nova-novncproxy nova-compute
    neutron-server neutron-linuxbridge-agent neutron-dhcp-agent
    neutron-metadata-agent neutron-l3-agent
    cinder-scheduler cinder-volume
    glance-api
    apache2
    rabbitmq-server
    memcached
    mariadb
)
for SVC in "${SERVICES[@]}"; do
    systemctl stop "${SVC}" 2>/dev/null || true
    systemctl disable "${SVC}" 2>/dev/null || true
done

# Purge packages
echo ">>> Removing all packages..."
apt-get purge -y \
    heat-api heat-api-cfn heat-engine python3-heatclient \
    nova-api nova-conductor nova-novncproxy nova-scheduler nova-compute \
    neutron-server neutron-plugin-ml2 neutron-linuxbridge-agent \
    neutron-l3-agent neutron-dhcp-agent neutron-metadata-agent \
    cinder-api cinder-scheduler cinder-volume \
    glance \
    placement-api \
    keystone python3-openstackclient python3-osc-placement \
    openstack-dashboard \
    apache2 libapache2-mod-wsgi-py3 \
    rabbitmq-server \
    memcached \
    mariadb-server mariadb-client \
    qemu-kvm libvirt-daemon-system \
    2>/dev/null || true

apt-get autoremove -y 2>/dev/null || true

# Complete MariaDB package state cleanup
echo ">>> Purging all MariaDB packages to clean dpkg state..."
apt-get purge mariadb-* mysql-* -y 2>/dev/null || true

# Complete OpenStack package cleanup to prevent broken states
echo ">>> Purging all OpenStack packages to clean dpkg state..."
apt-get purge glance* keystone* nova* neutron* cinder* placement* heat* horizon* openstack-dashboard* -y 2>/dev/null || true

# Remove data directories
echo ">>> Removing data and config directories..."
rm -rf /etc/keystone /etc/glance /etc/nova /etc/neutron /etc/cinder /etc/heat
rm -rf /etc/placement /etc/openstack-dashboard
rm -rf /var/lib/keystone /var/lib/glance /var/lib/nova /var/lib/neutron
rm -rf /var/lib/cinder /var/lib/heat /var/lib/placement
rm -rf /var/log/keystone /var/log/glance /var/log/nova /var/log/neutron
rm -rf /var/log/cinder /var/log/heat
rm -rf /var/lib/mysql /var/log/mysql /etc/mysql
rm -rf /var/lib/rabbitmq /var/log/rabbitmq /etc/rabbitmq
rm -rf /etc/apache2

# Remove credential files
rm -f /root/admin-openrc.sh /root/demo-openrc.sh

# Remove offline repo source
rm -f /etc/apt/sources.list.d/openstack-offline.list

# LVM cleanup
if [[ "${KEEP_LVM}" == "false" ]]; then
    echo ">>> Removing Cinder LVM..."
    vgremove -f "${CINDER_VG}" 2>/dev/null || true
    pvremove "${CINDER_DISK}" 2>/dev/null || true
else
    echo ">>> Keeping LVM volume group (--keep-lvm specified)."
fi

# Kernel modules and sysctl
rm -f /etc/sysctl.d/99-openstack-bridge.conf
sysctl --system >/dev/null 2>&1 || true

# Systemd reload
systemctl daemon-reload

echo ""
echo "=== OpenStack Completely Removed ==="
echo ""
echo "  Note: The air-gap cache at /opt/openstack-airgap/ was NOT removed."
echo "  To remove it: sudo rm -rf /opt/openstack-airgap"
echo ""
echo "  To reinstall, start from 01-base.sh"
