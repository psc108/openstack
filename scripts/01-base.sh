#!/usr/bin/env bash
# =============================================================================
# 01-base.sh — Base Infrastructure Services
# =============================================================================
# Installs and configures the three foundational services that every OpenStack
# component depends on:
#
#   1. MariaDB    — relational database (stores all OpenStack state)
#   2. RabbitMQ   — message broker (services communicate via AMQP queues)
#   3. Memcached  — in-memory cache (Keystone caches auth tokens here)
#
# Why these three?
#   OpenStack is a collection of microservices. They need a shared database,
#   a message bus for async communication, and a cache for performance.
#
# Usage:
#   sudo bash 01-base.sh              # Install
#   sudo bash 01-base.sh --uninstall  # Remove everything
#
# Re-run safe: Yes — nukes existing install first (idempotent)
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable variables
# -----------------------------------------------------------------------------
AIRGAP_DIR="/opt/openstack-airgap"
REPO_DIR="${AIRGAP_DIR}/repo"

# Database root password — change in production
DB_ROOT_PASS="changeit"

# RabbitMQ user for OpenStack services
RABBIT_USER="openstack"
RABBIT_PASS="changeit"

# Management IP — this machine's IP on the management network
# For a single-node laptop install, this is just the primary IP
MGMT_IP="127.0.0.1"

# Bind address for MariaDB — 0.0.0.0 for all interfaces, or lock to MGMT_IP
MARIADB_BIND="127.0.0.1"

# =============================================================================
# Uninstall mode
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Uninstalling base infrastructure ==="

    echo ">>> Stopping services..."
    systemctl stop mariadb rabbitmq-server memcached 2>/dev/null || true
    systemctl disable mariadb rabbitmq-server memcached 2>/dev/null || true

    echo ">>> Removing packages..."
    apt-get purge -y mariadb-server mariadb-client rabbitmq-server \
        memcached erlang-base 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    echo ">>> Removing data directories..."
    rm -rf /var/lib/mysql /var/log/mysql
    rm -rf /var/lib/rabbitmq /var/log/rabbitmq
    rm -rf /etc/mysql /etc/rabbitmq

    echo ">>> Reloading systemd..."
    systemctl daemon-reload

    echo "=== Base infrastructure removed ==="
    exit 0
fi

# =============================================================================
# Pre-flight checks
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)." >&2
    exit 1
fi

echo "=== Installing Base Infrastructure ==="
echo "  MariaDB bind:   ${MARIADB_BIND}"
echo "  RabbitMQ user:  ${RABBIT_USER}"
echo "  Management IP:  ${MGMT_IP}"
echo ""

# Ensure crudini is available (needed by all subsequent service scripts)
if ! command -v crudini &>/dev/null; then
    echo ">>> Installing crudini (INI file editor)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y crudini
fi

# -----------------------------------------------------------------------------
# Helper: install packages from air-gap repo or online
# -----------------------------------------------------------------------------
install_pkg() {
    if [[ -f "${REPO_DIR}/Packages" ]]; then
        # Ensure offline repo is active
        if [[ ! -f /etc/apt/sources.list.d/openstack-offline.list ]]; then
            cp "${AIRGAP_DIR}/openstack-offline.list" /etc/apt/sources.list.d/
            apt-get update -qq
        fi
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# -----------------------------------------------------------------------------
# Step 1: Nuke existing installation (idempotent)
# -----------------------------------------------------------------------------
echo ">>> Step 1: Removing any existing installation..."
systemctl stop mariadb rabbitmq-server memcached 2>/dev/null || true
rm -rf /var/lib/mysql /var/lib/rabbitmq 2>/dev/null || true

# -----------------------------------------------------------------------------
# Step 2: Install MariaDB
# -----------------------------------------------------------------------------
echo ">>> Step 2: Installing MariaDB..."
install_pkg mariadb-server python3-pymysql

# Configure MariaDB for OpenStack
# - InnoDB is required (default in MariaDB, but we ensure settings are optimal)
# - utf8mb4 character set for proper Unicode support
# - bind to management interface only
cat > /etc/mysql/mariadb.conf.d/99-openstack.cnf <<EOF
[mysqld]
bind-address = ${MARIADB_BIND}
default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8mb4_general_ci
character-set-server = utf8mb4
EOF

# Start and enable
systemctl enable --now mariadb
systemctl restart mariadb

# Secure the installation (equivalent of mysql_secure_installation)
# - Set root password
# - Remove anonymous users
# - Disallow remote root login
# - Remove test database
mariadb -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

echo "    MariaDB installed and secured."

# -----------------------------------------------------------------------------
# Step 3: Install RabbitMQ
# -----------------------------------------------------------------------------
echo ">>> Step 3: Installing RabbitMQ..."
install_pkg rabbitmq-server

# Start RabbitMQ
systemctl enable --now rabbitmq-server

# Create the OpenStack user with full permissions
# RabbitMQ users are how OpenStack services authenticate to the broker
rabbitmqctl delete_user "${RABBIT_USER}" 2>/dev/null || true
rabbitmqctl add_user "${RABBIT_USER}" "${RABBIT_PASS}"
rabbitmqctl set_permissions "${RABBIT_USER}" ".*" ".*" ".*"

echo "    RabbitMQ installed. User '${RABBIT_USER}' created."

# -----------------------------------------------------------------------------
# Step 4: Install Memcached
# -----------------------------------------------------------------------------
echo ">>> Step 4: Installing Memcached..."
install_pkg memcached python3-memcache

# Configure Memcached to listen on management IP
# By default it listens on 127.0.0.1 which is fine for single-node
sed -i "s/^-l .*/-l ${MGMT_IP}/" /etc/memcached.conf

systemctl enable --now memcached
systemctl restart memcached

echo "    Memcached installed, listening on ${MGMT_IP}:11211."

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Base Infrastructure Complete ==="
echo ""
echo "  MariaDB:"
echo "    Status:   $(systemctl is-active mariadb)"
echo "    Port:     3306"
echo "    Root pw:  ${DB_ROOT_PASS}"
echo ""
echo "  RabbitMQ:"
echo "    Status:   $(systemctl is-active rabbitmq-server)"
echo "    Port:     5672"
echo "    User:     ${RABBIT_USER} / ${RABBIT_PASS}"
echo ""
echo "  Memcached:"
echo "    Status:   $(systemctl is-active memcached)"
echo "    Port:     11211"
echo ""
echo "Next: Run 02-keystone.sh to install the identity service."
