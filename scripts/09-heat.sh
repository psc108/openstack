#!/usr/bin/env bash
# =============================================================================
# 09-heat.sh — OpenStack Orchestration Service (Heat)
# =============================================================================
# Heat provides infrastructure-as-code for OpenStack via HOT templates.
#
# What Heat does:
#   - Reads a YAML template describing desired infrastructure
#   - Creates/updates/deletes resources to match the template (a "stack")
#   - Manages dependencies between resources (network before subnet before VM)
#   - Supports auto-scaling, wait conditions, and software deployment
#   - Provides rollback on failure
#
# Example: a Heat template can create a network, subnet, router, security
# group, and 3 VMs with a single command. Delete the stack and it all goes.
#
# Architecture:
#   heat-api     — REST API for stack operations
#   heat-api-cfn — AWS CloudFormation-compatible API (legacy/compat)
#   heat-engine  — does the actual work of creating/deleting resources
#
# Heat needs TWO Keystone domains:
#   - 'heat' domain for stack users (Heat creates per-stack users for isolation)
#   - A 'heat_stack_owner' role for users who can create stacks
#   - A 'heat_stack_user' role for the auto-created stack users
#
# Usage:
#   sudo bash 09-heat.sh
#   sudo bash 09-heat.sh --uninstall
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
AIRGAP_DIR="/opt/openstack-airgap"
REPO_DIR="${AIRGAP_DIR}/repo"

DB_ROOT_PASS="changeit"
HEAT_DB_PASS="changeit"
HEAT_PASS="changeit"
HEAT_DOMAIN_ADMIN_PASS="changeit"
RABBIT_PASS="changeit"

CONTROLLER="localhost"
REGION="RegionOne"

# =============================================================================
# Uninstall mode
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Uninstalling Heat ==="
    systemctl stop heat-api heat-api-cfn heat-engine 2>/dev/null || true
    systemctl disable heat-api heat-api-cfn heat-engine 2>/dev/null || true
    apt-get purge -y heat-api heat-api-cfn heat-engine python3-heatclient python3-heat-dashboard heat-dashboard-common 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS heat;" 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP USER IF EXISTS 'heat'@'localhost';" 2>/dev/null || true
    mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP USER IF EXISTS 'heat'@'%';" 2>/dev/null || true
    rm -rf /etc/heat /var/lib/heat /var/log/heat
    echo "=== Heat removed ==="
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

echo "=== Installing Heat (Orchestration Service) ==="
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
echo ">>> Step 1: Creating Heat database..."
mariadb -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS heat;
CREATE USER IF NOT EXISTS 'heat'@'localhost' IDENTIFIED BY '${HEAT_DB_PASS}';
CREATE USER IF NOT EXISTS 'heat'@'%' IDENTIFIED BY '${HEAT_DB_PASS}';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%';
FLUSH PRIVILEGES;
EOF

# -----------------------------------------------------------------------------
# Step 2: Register in Keystone
# -----------------------------------------------------------------------------
echo ">>> Step 2: Registering Heat in Keystone..."

# Service user
openstack user create --domain default --password "${HEAT_PASS}" heat 2>/dev/null || \
    openstack user set --password "${HEAT_PASS}" heat
openstack role add --project service --user heat admin 2>/dev/null || true

# Two services: orchestration (HOT) and cloudformation (CFN compat)
openstack service create --name heat --description "Orchestration" orchestration 2>/dev/null || true
openstack service create --name heat-cfn --description "Orchestration (CFN)" cloudformation 2>/dev/null || true

# Orchestration endpoints
for IFACE in public internal admin; do
    openstack endpoint create --region "${REGION}" orchestration "${IFACE}" \
        "http://${CONTROLLER}:8004/v1/%(tenant_id)s" 2>/dev/null || true
done

# CloudFormation endpoints
for IFACE in public internal admin; do
    openstack endpoint create --region "${REGION}" cloudformation "${IFACE}" \
        "http://${CONTROLLER}:8000/v1" 2>/dev/null || true
done

# Clean up any duplicate orchestration services (can happen on re-runs)
echo "    Cleaning up duplicate services..."
DUPLICATE_SERVICES=$(openstack service list -f value | grep orchestration | cut -d' ' -f1 | tail -n +2)
for SERVICE_ID in $DUPLICATE_SERVICES; do
    # Only delete services with no endpoints
    ENDPOINT_COUNT=$(openstack endpoint list --service "$SERVICE_ID" -f value 2>/dev/null | wc -l)
    if [[ $ENDPOINT_COUNT -eq 0 ]]; then
        echo "    Removing duplicate service: $SERVICE_ID"
        openstack service delete "$SERVICE_ID" 2>/dev/null || true
    fi
done

# -----------------------------------------------------------------------------
# Step 3: Create Heat domain and roles
# -----------------------------------------------------------------------------
# Heat manages its own Keystone domain for stack-scoped users.
# This provides isolation — a stack's resources are owned by a temporary user
# that gets deleted when the stack is torn down.
echo ">>> Step 3: Creating Heat domain and roles..."

# Create the 'heat' domain
openstack domain create --description "Stack projects and users" heat 2>/dev/null || true

# Create a domain admin user (Heat uses this to manage stack users)
openstack user create --domain heat --password "${HEAT_DOMAIN_ADMIN_PASS}" heat_domain_admin 2>/dev/null || \
    openstack user set --domain heat --password "${HEAT_DOMAIN_ADMIN_PASS}" heat_domain_admin
openstack role add --domain heat --user-domain heat --user heat_domain_admin admin 2>/dev/null || true

# Roles for stack operations
openstack role create heat_stack_owner 2>/dev/null || true
openstack role create heat_stack_user 2>/dev/null || true

# Give admin the stack_owner role so they can create stacks
openstack role add --project admin --user admin heat_stack_owner 2>/dev/null || true

# -----------------------------------------------------------------------------
# Step 4: Install packages
# -----------------------------------------------------------------------------
echo ">>> Step 4: Installing Heat..."
install_pkg heat-api heat-api-cfn heat-engine python3-heatclient

# Install Heat dashboard for Horizon integration
echo "    Installing Heat dashboard..."
install_pkg python3-heat-dashboard heat-dashboard-common

# -----------------------------------------------------------------------------
# Step 5: Configure Heat
# -----------------------------------------------------------------------------
echo ">>> Step 5: Configuring Heat..."

HEAT_CONF="/etc/heat/heat.conf"

# Database
crudini --set "${HEAT_CONF}" database connection \
    "mysql+pymysql://heat:${HEAT_DB_PASS}@${CONTROLLER}/heat"

# RabbitMQ
crudini --set "${HEAT_CONF}" DEFAULT transport_url \
    "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER}:5672/"

# Auth
crudini --set "${HEAT_CONF}" keystone_authtoken www_authenticate_uri "http://${CONTROLLER}:5000"
crudini --set "${HEAT_CONF}" keystone_authtoken auth_url "http://${CONTROLLER}:5000/v3"
crudini --set "${HEAT_CONF}" keystone_authtoken memcached_servers "${CONTROLLER}:11211"
crudini --set "${HEAT_CONF}" keystone_authtoken auth_type "password"
crudini --set "${HEAT_CONF}" keystone_authtoken project_domain_name "Default"
crudini --set "${HEAT_CONF}" keystone_authtoken user_domain_name "Default"
crudini --set "${HEAT_CONF}" keystone_authtoken project_name "service"
crudini --set "${HEAT_CONF}" keystone_authtoken username "heat"
crudini --set "${HEAT_CONF}" keystone_authtoken password "${HEAT_PASS}"

# Trustee — Heat creates trusts to act on behalf of users
crudini --set "${HEAT_CONF}" trustee auth_type "password"
crudini --set "${HEAT_CONF}" trustee auth_url "http://${CONTROLLER}:5000/v3"
crudini --set "${HEAT_CONF}" trustee username "heat"
crudini --set "${HEAT_CONF}" trustee password "${HEAT_PASS}"
crudini --set "${HEAT_CONF}" trustee user_domain_name "Default"

# Stack domain config
crudini --set "${HEAT_CONF}" DEFAULT heat_metadata_server_url "http://${CONTROLLER}:8000"
crudini --set "${HEAT_CONF}" DEFAULT heat_waitcondition_server_url "http://${CONTROLLER}:8000/v1/waitcondition"
crudini --set "${HEAT_CONF}" DEFAULT stack_domain_admin "heat_domain_admin"
crudini --set "${HEAT_CONF}" DEFAULT stack_domain_admin_password "${HEAT_DOMAIN_ADMIN_PASS}"
crudini --set "${HEAT_CONF}" DEFAULT stack_user_domain_name "heat"

# Auth strategy
crudini --set "${HEAT_CONF}" DEFAULT auth_strategy "keystone"

# Clients auth
crudini --set "${HEAT_CONF}" clients_keystone auth_uri "http://${CONTROLLER}:5000"

# -----------------------------------------------------------------------------
# Step 6: Sync database
# -----------------------------------------------------------------------------
echo ">>> Step 6: Syncing Heat database..."
su -s /bin/sh -c "heat-manage db_sync" heat

# -----------------------------------------------------------------------------
# Step 7: Start services
# -----------------------------------------------------------------------------
echo ">>> Step 7: Starting Heat services..."
for SVC in heat-api heat-api-cfn heat-engine; do
    systemctl enable --now "${SVC}"
    systemctl restart "${SVC}"
done

sleep 3

# -----------------------------------------------------------------------------
# Step 8: Horizon dashboard integration
# -----------------------------------------------------------------------------
echo ">>> Step 8: Integrating Heat dashboard with Horizon..."

# Copy Heat dashboard enabled files to Horizon
cp /usr/lib/python3/dist-packages/heat_dashboard/enabled/*.py /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/
echo "    Heat dashboard panels copied to Horizon"

# Restart Apache to pick up new Heat dashboard
cd /usr/share/openstack-dashboard
python3 manage.py collectstatic --noinput >/dev/null 2>&1 || echo "    Warning: collectstatic failed"
python3 manage.py compress --force >/dev/null 2>&1 || echo "    Warning: compress failed"

# Clear Python cache and restart Apache
find /usr/lib/python3/dist-packages/openstack_dashboard/ -name "*.pyc" -delete 2>/dev/null || true
find /usr/lib/python3/dist-packages/openstack_dashboard/ -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
systemctl restart apache2

echo "    Heat dashboard integrated - check Project → Orchestration in Horizon"

# -----------------------------------------------------------------------------
# Step 9: Verify
# -----------------------------------------------------------------------------
echo ">>> Step 9: Verifying Heat..."
echo "  Orchestration services:"
openstack orchestration service list 2>/dev/null || echo "    (waiting for engine to register)"

if openstack stack list >/dev/null 2>&1; then
    echo "    ✓ Heat operational — stack list accessible."
else
    echo "    ⚠ Heat may need a moment to fully start."
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Heat Installation Complete ==="
echo ""
echo "  Orchestration API:     http://${CONTROLLER}:8004/v1"
echo "  CloudFormation API:    http://${CONTROLLER}:8000/v1"
echo "  Horizon Dashboard:     Project → Orchestration → Stacks"
echo ""
echo "  Example usage:"
echo "    openstack stack create -t my-template.yaml my-stack"
echo ""
echo "Next: Run 10-post-install.sh for final networking setup and verification."
