#!/usr/bin/env bash
# =============================================================================
# 08-horizon.sh — OpenStack Dashboard (Horizon)
# =============================================================================
# Horizon is the web UI for OpenStack — a Django application served by Apache.
#
# What you get:
#   - Launch and manage instances (VMs)
#   - Create networks, routers, security groups
#   - Manage volumes (Cinder)
#   - Upload images (Glance)
#   - Manage users and projects (Keystone)
#   - Deploy stacks (Heat)
#   - All via a browser — no CLI needed
#
# Horizon doesn't have its own database or Keystone service user — it acts
# as a proxy, authenticating as the logged-in user for all API calls.
#
# Usage:
#   sudo bash 08-horizon.sh
#   sudo bash 08-horizon.sh --uninstall
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
AIRGAP_DIR="/opt/openstack-airgap"
REPO_DIR="${AIRGAP_DIR}/repo"

CONTROLLER="localhost"
MGMT_IP="127.0.0.1"

# Allowed hosts for Django (who can access the dashboard)
ALLOWED_HOSTS="*"

# Time zone
TIMEZONE="Europe/London"

# =============================================================================
# Uninstall mode
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Uninstalling Horizon ==="
    apt-get purge -y openstack-dashboard 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    rm -rf /etc/openstack-dashboard
    systemctl restart apache2 2>/dev/null || true
    echo "=== Horizon removed ==="
    exit 0
fi

# =============================================================================
# Pre-flight
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root." >&2
    exit 1
fi

echo "=== Installing Horizon (Dashboard) ==="
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
# Step 1: Install packages
# -----------------------------------------------------------------------------
echo ">>> Step 1: Installing Horizon..."
install_pkg openstack-dashboard

# -----------------------------------------------------------------------------
# Step 2: Configure Horizon
# -----------------------------------------------------------------------------
echo ">>> Step 2: Configuring Horizon..."

HORIZON_CONF="/etc/openstack-dashboard/local_settings.py"

# Keystone URL — where the dashboard sends auth requests
sed -i "s|^OPENSTACK_HOST.*|OPENSTACK_HOST = \"${CONTROLLER}\"|" "${HORIZON_CONF}"

# Allow access from any host (laptop only — restrict in production)
sed -i "s|^ALLOWED_HOSTS.*|ALLOWED_HOSTS = ['${ALLOWED_HOSTS}']|" "${HORIZON_CONF}"

# Memcached session backend (faster than DB sessions)
# Replace the default cache config
python3 -c "
import re
conf = open('${HORIZON_CONF}').read()
# Set memcached as session engine
if 'django.contrib.sessions.backends.cache' not in conf:
    conf = conf.replace(
        \"SESSION_ENGINE = 'django.contrib.sessions.backends.db'\",
        \"SESSION_ENGINE = 'django.contrib.sessions.backends.cache'\"
    )
# Update CACHES to use memcached
cache_block = '''CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
        'LOCATION': '${CONTROLLER}:11211',
    }
}'''
conf = re.sub(r'CACHES\s*=\s*\{[^}]*\{[^}]*\}[^}]*\}', cache_block, conf, flags=re.DOTALL)
open('${HORIZON_CONF}', 'w').write(conf)
" 2>/dev/null || true

# Keystone API version
if ! grep -q "OPENSTACK_KEYSTONE_URL" "${HORIZON_CONF}"; then
    echo "OPENSTACK_KEYSTONE_URL = \"http://${CONTROLLER}:5000/v3\"" >> "${HORIZON_CONF}"
else
    sed -i "s|^OPENSTACK_KEYSTONE_URL.*|OPENSTACK_KEYSTONE_URL = \"http://${CONTROLLER}:5000/v3\"|" "${HORIZON_CONF}"
fi

# Enable Identity API v3
if ! grep -q "OPENSTACK_API_VERSIONS" "${HORIZON_CONF}"; then
    cat >> "${HORIZON_CONF}" <<'EOF'

OPENSTACK_API_VERSIONS = {
    "identity": 3,
    "image": 2,
    "volume": 3,
}
EOF
fi

# Default domain
if ! grep -q "OPENSTACK_KEYSTONE_DEFAULT_DOMAIN" "${HORIZON_CONF}"; then
    echo "OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = \"Default\"" >> "${HORIZON_CONF}"
fi

# Default role for new users
if ! grep -q "OPENSTACK_KEYSTONE_DEFAULT_ROLE" "${HORIZON_CONF}"; then
    echo "OPENSTACK_KEYSTONE_DEFAULT_ROLE = \"member\"" >> "${HORIZON_CONF}"
fi

# Time zone
sed -i "s|^TIME_ZONE.*|TIME_ZONE = \"${TIMEZONE}\"|" "${HORIZON_CONF}"

# Enable multi-domain support
if ! grep -q "OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT" "${HORIZON_CONF}"; then
    echo "OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True" >> "${HORIZON_CONF}"
fi

echo "    Dashboard configured."

# -----------------------------------------------------------------------------
# Step 3: Restart Apache
# -----------------------------------------------------------------------------
echo ">>> Step 3: Restarting Apache..."
systemctl restart apache2

# -----------------------------------------------------------------------------
# Step 4: Verify
# -----------------------------------------------------------------------------
echo ">>> Step 4: Verifying Horizon..."

sleep 2
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${MGMT_IP}/horizon/auth/login/" 2>/dev/null || echo "000")

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "    ✓ Horizon operational — login page accessible."
else
    echo "    ⚠ HTTP ${HTTP_CODE} — Dashboard may need Apache restart."
    echo "    Try: http://${MGMT_IP}/horizon/"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Horizon Installation Complete ==="
echo ""
echo "  URL:       http://${MGMT_IP}/horizon/"
echo "  Username:  admin"
echo "  Password:  changeit"
echo "  Domain:    Default"
echo ""
echo "Next: Run 09-heat.sh to install the orchestration service."
