#!/usr/bin/env bash
# =============================================================================
# 02-keystone.sh — OpenStack Identity Service (Keystone)
# =============================================================================
# Keystone is the authentication and authorisation backbone of OpenStack.
# Every other service registers with Keystone and uses it to validate tokens.
#
# What Keystone provides:
#   - User/group/project/domain management
#   - Token issuance (Fernet tokens — symmetric key, no DB lookup needed)
#   - Service catalogue (registry of all OpenStack endpoints)
#   - Policy enforcement (who can do what)
#
# Architecture:
#   Keystone runs as a WSGI application inside Apache (mod_wsgi).
#   This is the recommended production deployment — Apache handles
#   concurrency, TLS termination, and process management.
#
# Usage:
#   sudo bash 02-keystone.sh
#   sudo bash 02-keystone.sh --uninstall
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
AIRGAP_DIR="/opt/openstack-airgap"
REPO_DIR="${AIRGAP_DIR}/repo"

DB_ROOT_PASS="changeit"
KEYSTONE_DB_PASS="changeit"
ADMIN_PASS="changeit"

# Controller hostname — for a single-node install, use the machine hostname
CONTROLLER="localhost"
MGMT_IP="127.0.0.1"

# Region — OpenStack organises endpoints by region
REGION="RegionOne"

# =============================================================================
# Uninstall mode
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Uninstalling Keystone ==="

    systemctl stop apache2 2>/dev/null || true

    apt-get purge -y keystone python3-openstackclient apache2 \
        libapache2-mod-wsgi-py3 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    # Drop database
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS keystone;" 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP USER IF EXISTS 'keystone'@'localhost';" 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP USER IF EXISTS 'keystone'@'%';" 2>/dev/null || true

    rm -rf /etc/keystone /var/log/keystone
    rm -f /etc/apache2/sites-available/keystone.conf
    rm -f /root/admin-openrc.sh

    echo "=== Keystone removed ==="
    exit 0
fi

# =============================================================================
# Pre-flight checks
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root." >&2
    exit 1
fi

echo "=== Installing Keystone (Identity Service) ==="
echo ""

# -----------------------------------------------------------------------------
# Helper
# -----------------------------------------------------------------------------
install_pkg() {
    if [[ -f "${REPO_DIR}/Packages" ]] && \
       [[ ! -f /etc/apt/sources.list.d/openstack-offline.list ]]; then
        cp "${AIRGAP_DIR}/openstack-offline.list" /etc/apt/sources.list.d/
        apt-get update -qq
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# -----------------------------------------------------------------------------
# Step 1: Create the Keystone database
# -----------------------------------------------------------------------------
# Every OpenStack service gets its own database and dedicated DB user.
# This isolates services and limits blast radius of a credential leak.
echo ">>> Step 1: Creating Keystone database..."

mariadb -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS keystone;
CREATE USER IF NOT EXISTS 'keystone'@'localhost' IDENTIFIED BY '${KEYSTONE_DB_PASS}';
CREATE USER IF NOT EXISTS 'keystone'@'%' IDENTIFIED BY '${KEYSTONE_DB_PASS}';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%';
FLUSH PRIVILEGES;
EOF

echo "    Database 'keystone' ready."

# -----------------------------------------------------------------------------
# Step 2: Install Keystone packages
# -----------------------------------------------------------------------------
echo ">>> Step 2: Installing Keystone packages..."
install_pkg keystone python3-openstackclient apache2 libapache2-mod-wsgi-py3

# -----------------------------------------------------------------------------
# Step 3: Configure Keystone
# -----------------------------------------------------------------------------
# The main config file is /etc/keystone/keystone.conf
# Key settings:
#   [database] connection — points to our MariaDB
#   [token] provider — Fernet (stateless, fast, no DB bloat)
echo ">>> Step 3: Configuring Keystone..."

KEYSTONE_CONF="/etc/keystone/keystone.conf"

# Backup original
cp "${KEYSTONE_CONF}" "${KEYSTONE_CONF}.orig" 2>/dev/null || true

# Set database connection
# Format: mysql+pymysql://user:pass@host/dbname
crudini --set "${KEYSTONE_CONF}" database connection \
    "mysql+pymysql://keystone:${KEYSTONE_DB_PASS}@${CONTROLLER}/keystone"

# Set Fernet token provider
# Fernet tokens are:
#   - Cryptographically signed (tamper-proof)
#   - Not stored in the database (no token flush needed)
#   - Rotated via key repository (/etc/keystone/fernet-keys/)
crudini --set "${KEYSTONE_CONF}" token provider fernet

echo "    Configuration written."

# -----------------------------------------------------------------------------
# Step 4: Populate the database schema
# -----------------------------------------------------------------------------
# db_sync creates all tables Keystone needs. This is idempotent — safe to re-run.
echo ">>> Step 4: Populating Keystone database schema..."
su -s /bin/sh -c "keystone-manage db_sync" keystone

# -----------------------------------------------------------------------------
# Step 5: Initialise Fernet key repositories
# -----------------------------------------------------------------------------
# Fernet keys are used to sign/encrypt tokens.
# credential-setup creates keys for encrypting credentials stored in the DB.
echo ">>> Step 5: Initialising Fernet keys..."

keystone-manage fernet_setup \
    --keystone-user keystone --keystone-group keystone

keystone-manage credential_setup \
    --keystone-user keystone --keystone-group keystone

echo "    Fernet and credential keys initialised."

# -----------------------------------------------------------------------------
# Step 6: Bootstrap Keystone
# -----------------------------------------------------------------------------
# This creates:
#   - The 'admin' user with the specified password
#   - The 'admin' project and role
#   - The service catalogue entry for Keystone itself
#   - The three standard endpoints (public, internal, admin)
echo ">>> Step 6: Bootstrapping Keystone..."

keystone-manage bootstrap \
    --bootstrap-password "${ADMIN_PASS}" \
    --bootstrap-admin-url "http://${CONTROLLER}:5000/v3/" \
    --bootstrap-internal-url "http://${CONTROLLER}:5000/v3/" \
    --bootstrap-public-url "http://${CONTROLLER}:5000/v3/" \
    --bootstrap-region-id "${REGION}"

echo "    Admin user and endpoints created."

# -----------------------------------------------------------------------------
# Step 7: Configure Apache to serve Keystone
# -----------------------------------------------------------------------------
# Keystone is a WSGI app. Apache + mod_wsgi gives us:
#   - Multi-process handling (pre-fork MPM)
#   - Graceful restarts
#   - Future TLS termination
echo ">>> Step 7: Configuring Apache..."

# Set ServerName to avoid warnings
if ! grep -q "^ServerName" /etc/apache2/apache2.conf; then
    echo "ServerName ${CONTROLLER}" >> /etc/apache2/apache2.conf
fi

systemctl enable --now apache2
systemctl restart apache2

echo "    Apache configured and running."

# -----------------------------------------------------------------------------
# Step 8: Create admin credential file
# -----------------------------------------------------------------------------
# This file sets environment variables so the 'openstack' CLI knows how to
# authenticate. Source it before running any openstack commands.
echo ">>> Step 8: Creating admin-openrc.sh..."

cat > /root/admin-openrc.sh <<EOF
# OpenStack admin credentials
# Usage: source /root/admin-openrc.sh
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASS}
export OS_AUTH_URL=http://${CONTROLLER}:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

chmod 600 /root/admin-openrc.sh
echo "    /root/admin-openrc.sh created (source this to use CLI)."

# -----------------------------------------------------------------------------
# Step 9: Verify
# -----------------------------------------------------------------------------
echo ">>> Step 9: Verifying Keystone..."
source /root/admin-openrc.sh

# Request a token — if this works, Keystone is functional
if openstack token issue >/dev/null 2>&1; then
    echo "    ✓ Keystone is operational — token issued successfully."
else
    echo "    ✗ ERROR: Could not issue token. Check logs: /var/log/keystone/"
    exit 1
fi

# Create the 'service' project — all OpenStack service users live here
openstack project create --domain default --description "Service Project" service 2>/dev/null || true

# Show service catalogue
echo ""
echo "  Service catalogue:"
openstack catalog list 2>/dev/null || echo "    (catalogue empty — services not yet registered)"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Keystone Installation Complete ==="
echo ""
echo "  Endpoint:     http://${CONTROLLER}:5000/v3/"
echo "  Admin user:   admin / ${ADMIN_PASS}"
echo "  Credentials:  source /root/admin-openrc.sh"
echo ""
echo "Next: Run 03-glance.sh to install the image service."
