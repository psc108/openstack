#!/usr/bin/env bash
# =============================================================================
# 03-glance.sh — OpenStack Image Service (Glance)
# =============================================================================
# Glance manages VM images — the disk templates used to launch instances.
#
# What Glance provides:
#   - Image upload, discovery, and retrieval via REST API
#   - Support for multiple formats: qcow2, raw, vmdk, vhd, iso
#   - Image metadata (min RAM, min disk, architecture, etc.)
#   - Copy-on-write support with Cinder/Nova
#
# Storage backend:
#   We use the local filesystem (/var/lib/glance/images/) — simplest option
#   for a single-node install. Production would use Ceph, Swift, or S3.
#
# Usage:
#   sudo bash 03-glance.sh
#   sudo bash 03-glance.sh --uninstall
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
AIRGAP_DIR="/opt/openstack-airgap"
REPO_DIR="${AIRGAP_DIR}/repo"
IMAGES_DIR="${AIRGAP_DIR}/images"

DB_ROOT_PASS="changeit"
GLANCE_DB_PASS="changeit"
GLANCE_PASS="changeit"

CONTROLLER="localhost"
REGION="RegionOne"

# =============================================================================
# Uninstall mode
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Uninstalling Glance ==="
    systemctl stop glance-api 2>/dev/null || true
    systemctl disable glance-api 2>/dev/null || true
    apt-get purge -y glance 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS glance;" 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP USER IF EXISTS 'glance'@'localhost';" 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP USER IF EXISTS 'glance'@'%';" 2>/dev/null || true
    rm -rf /etc/glance /var/lib/glance /var/log/glance
    echo "=== Glance removed ==="
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

echo "=== Installing Glance (Image Service) ==="
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
echo ">>> Step 1: Creating Glance database..."
mariadb -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS glance;
CREATE USER IF NOT EXISTS 'glance'@'localhost' IDENTIFIED BY '${GLANCE_DB_PASS}';
CREATE USER IF NOT EXISTS 'glance'@'%' IDENTIFIED BY '${GLANCE_DB_PASS}';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%';
FLUSH PRIVILEGES;
EOF

# -----------------------------------------------------------------------------
# Step 2: Create Keystone entities
# -----------------------------------------------------------------------------
# Every OpenStack service needs:
#   - A service user (for inter-service auth)
#   - A service entry in the catalogue
#   - Endpoints (public, internal, admin)
echo ">>> Step 2: Registering Glance in Keystone..."

# Create 'glance' user in the 'service' project
openstack user create --domain default --password "${GLANCE_PASS}" glance 2>/dev/null || \
    openstack user set --password "${GLANCE_PASS}" glance

# Grant admin role (services need admin to validate tokens)
openstack role add --project service --user glance admin 2>/dev/null || true

# Create the 'image' service
openstack service create --name glance --description "OpenStack Image" image 2>/dev/null || true

# Create endpoints
for IFACE in public internal admin; do
    openstack endpoint create --region "${REGION}" image "${IFACE}" \
        "http://${CONTROLLER}:9292" 2>/dev/null || true
done

echo "    Glance registered in service catalogue."

# -----------------------------------------------------------------------------
# Step 3: Install packages
# -----------------------------------------------------------------------------
echo ">>> Step 3: Installing Glance..."
install_pkg glance

# -----------------------------------------------------------------------------
# Step 4: Configure Glance
# -----------------------------------------------------------------------------
echo ">>> Step 4: Configuring Glance..."

GLANCE_CONF="/etc/glance/glance-api.conf"

# Database connection
crudini --set "${GLANCE_CONF}" database connection \
    "mysql+pymysql://glance:${GLANCE_DB_PASS}@${CONTROLLER}/glance"

# Keystone authentication — Glance validates tokens via Keystone
crudini --set "${GLANCE_CONF}" keystone_authtoken www_authenticate_uri "http://${CONTROLLER}:5000"
crudini --set "${GLANCE_CONF}" keystone_authtoken auth_url "http://${CONTROLLER}:5000/v3"
crudini --set "${GLANCE_CONF}" keystone_authtoken memcached_servers "${CONTROLLER}:11211"
crudini --set "${GLANCE_CONF}" keystone_authtoken auth_type "password"
crudini --set "${GLANCE_CONF}" keystone_authtoken project_domain_name "Default"
crudini --set "${GLANCE_CONF}" keystone_authtoken user_domain_name "Default"
crudini --set "${GLANCE_CONF}" keystone_authtoken project_name "service"
crudini --set "${GLANCE_CONF}" keystone_authtoken username "glance"
crudini --set "${GLANCE_CONF}" keystone_authtoken password "${GLANCE_PASS}"

# Use Keystone for auth (paste deploy pipeline)
crudini --set "${GLANCE_CONF}" paste_deploy flavor "keystone"

# Store images on local filesystem
crudini --set "${GLANCE_CONF}" glance_store stores "file,http"
crudini --set "${GLANCE_CONF}" glance_store default_store "file"
crudini --set "${GLANCE_CONF}" glance_store filesystem_store_datadir "/var/lib/glance/images/"

# Ensure image directory exists
mkdir -p /var/lib/glance/images/
chown glance:glance /var/lib/glance/images/

# Create API paste configuration if missing
if [[ ! -f "/etc/glance/glance-api-paste.ini" ]]; then
    echo ">>> Creating Glance API paste configuration..."
    cat > /etc/glance/glance-api-paste.ini << 'EOF'
[composite:glance-api]
use = egg:Paste#urlmap
/: apiversions
/v1: apiv1app
/v2: apiv2app

[composite:apiversions]
use = call:glance.api.versions:create_resource

[composite:apiv1app]
use = call:glance.api.v1.router:API.factory

[composite:apiv2app]
use = call:glance.api.v2.router:API.factory

[pipeline:apiv1app]
pipeline = cors healthcheck versionnegotiation authtoken context rootapp

[pipeline:apiv2app]
pipeline = cors healthcheck versionnegotiation authtoken context rootapp

[app:rootapp]
paste.app_factory = glance.api.v2.router:API.factory

[filter:healthcheck]
paste.filter_factory = oslo_middleware:Healthcheck.factory
backends = disable_by_file
disable_by_files = /etc/glance/healthcheck_disable

[filter:versionnegotiation]
paste.filter_factory = glance.api.middleware.version_negotiation:VersionNegotiationFilter.factory

[filter:cors]
paste.filter_factory = oslo_middleware.cors:filter_factory
oslo_config_project = glance

[filter:context]
paste.filter_factory = glance.api.middleware.context:ContextMiddleware.factory

[filter:authtoken]
paste.filter_factory = keystonemiddleware.auth_token:filter_factory
EOF
    chown glance:glance /etc/glance/glance-api-paste.ini
fi

# -----------------------------------------------------------------------------
# Step 5: Populate database
# -----------------------------------------------------------------------------
echo ">>> Step 5: Syncing Glance database..."
su -s /bin/sh -c "glance-manage db_sync" glance

# -----------------------------------------------------------------------------
# Step 6: Start service
# -----------------------------------------------------------------------------
echo ">>> Step 6: Starting Glance..."
systemctl enable --now glance-api
systemctl restart glance-api

# Give it a moment to start
sleep 2

# -----------------------------------------------------------------------------
# Step 7: Upload test image
# -----------------------------------------------------------------------------
echo ">>> Step 7: Uploading CirrOS test image..."

CIRROS_FILE="${IMAGES_DIR}/cirros-0.6.2-x86_64-disk.img"

if openstack image show cirros >/dev/null 2>&1; then
    echo "    CirrOS image already exists."
else
    if [[ -f "${CIRROS_FILE}" ]]; then
        openstack image create "cirros" \
            --file "${CIRROS_FILE}" \
            --disk-format qcow2 \
            --container-format bare \
            --public
        echo "    CirrOS image uploaded from air-gap cache."
    else
        echo "    WARNING: CirrOS image not found at ${CIRROS_FILE}"
        echo "    Run 00-download.sh first, or upload manually later."
    fi
fi

# -----------------------------------------------------------------------------
# Step 8: Verify
# -----------------------------------------------------------------------------
echo ">>> Step 8: Verifying Glance..."
if openstack image list | grep -q "cirros"; then
    echo "    ✓ Glance operational — CirrOS image available."
else
    echo "    ⚠ Glance running but no images loaded yet."
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Glance Installation Complete ==="
echo ""
echo "  Endpoint:  http://${CONTROLLER}:9292"
echo "  Storage:   /var/lib/glance/images/"
echo ""
echo "Next: Run 04-placement.sh to install the placement service."
