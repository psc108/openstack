#!/usr/bin/env bash
# =============================================================================
# 13-mistral-ai-core.sh — Mistral AI OpenStack Core Agent Installation
# =============================================================================
# Installs the foundation for AI-powered OpenStack automation using Mistral AI.
# Creates the core Python environment, service user, and foundational modules
# for natural language infrastructure management.
#
# What it installs:
#   - Python virtual environment with Mistral AI SDK
#   - OpenStack SDK and client libraries
#   - Service user (mistral) with proper permissions
#   - Core modules: client.py, os_client.py, rollback.py
#   - Transaction management and resource tracking
#   - Quota checking and cost estimation framework
#   - Redis integration for caching and session state
#   - Tools framework with handler registry
#
# Prerequisites:
#   - 01-base.sh (Redis server for state management)
#   - 02-keystone.sh (OpenStack authentication)
#   - Basic OpenStack deployment with working API endpoints
#
# Usage:
#   sudo bash 13-mistral-ai-core.sh           # Install core components
#   sudo bash 13-mistral-ai-core.sh --uninstall # Remove installation
#
# Post-install:
#   Set MISTRAL_API_KEY environment variable
#   Run 14-17 scripts to install tool modules
#   Run 18-19 for agent and dashboard integration
#
# Re-run safe: Yes (nuke-first approach)
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/mistral-openstack"
VENV_DIR="$INSTALL_DIR/venv"
CONFIG_DIR="/etc/mistral-openstack"
LOG_DIR="/var/log/mistral-os"
AUDIT_LOG="$LOG_DIR/audit.log"

# Python package versions
MISTRAL_VERSION=">=1.0.0"
OPENSTACK_SDK_VERSION=">=3.0.0"
PYTHON_OPENSTACK_CLIENT_VERSION=">=6.0.0"
TENACITY_VERSION=">=8.0.0"

# Service user
SERVICE_USER="mistral"

# ── Functions ─────────────────────────────────────────────────────────────────

install_pkg() {
    local pkg="$1"
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "Installing $pkg..."
        apt-get install -y "$pkg"
    fi
}

create_service_user() {
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        echo "Creating service user: $SERVICE_USER"
        useradd --system --shell /bin/bash --home-dir "$INSTALL_DIR" --create-home "$SERVICE_USER"
    fi
}

setup_directories() {
    echo "Setting up directories..."
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$LOG_DIR"
    chmod 755 "$CONFIG_DIR"
    chmod 750 "$LOG_DIR"
}

create_virtual_environment() {
    echo "Creating Python virtual environment..."
    sudo -u "$SERVICE_USER" python3 -m venv "$VENV_DIR"
    
    # Upgrade pip
    sudo -u "$SERVICE_USER" "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel
    
    # Install core dependencies
    echo "Installing Python dependencies..."
    # First remove any conflicting packages
    sudo -u "$SERVICE_USER" "$VENV_DIR/bin/pip" uninstall -y mistralai python-mistralclient || true
    
    # Install the correct Mistral AI client package
    sudo -u "$SERVICE_USER" "$VENV_DIR/bin/pip" install \
        "mistralai==0.4.2" \
        "openstacksdk$OPENSTACK_SDK_VERSION" \
        "python-openstackclient$PYTHON_OPENSTACK_CLIENT_VERSION" \
        "tenacity$TENACITY_VERSION" \
        redis
}

create_client_module() {
    echo "Creating client.py..."
    cat > "$INSTALL_DIR/client.py" << 'EOF'
import os
from mistralai.client import MistralClient
from tenacity import retry, stop_after_attempt, wait_exponential

@retry(
    wait=wait_exponential(multiplier=1, min=2, max=30),
    stop=stop_after_attempt(3),
)
def get_mistral_client() -> MistralClient:
    api_key = os.environ.get("MISTRAL_API_KEY")
    if not api_key:
        raise RuntimeError("MISTRAL_API_KEY is not set")
    
    # Create client with API key
    return MistralClient(api_key=api_key)
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/client.py"
}

create_os_client_module() {
    echo "Creating os_client.py..."
    cat > "$INSTALL_DIR/os_client.py" << 'EOF'
import openstack
import threading

# Per-request connection for Horizon context
_REQUEST_CONN = threading.local()

def set_request_conn(conn) -> None:
    """Set per-request connection for Horizon context."""
    _REQUEST_CONN.conn = conn

def get_conn() -> openstack.connection.Connection:
    """
    Returns an OpenStack connection using environment-variable auth.
    If a per-request connection has been set (Horizon context), use it.
    Otherwise fall back to environment-variable auth (CLI context).
    """
    return getattr(_REQUEST_CONN, "conn", None) or openstack.connect()
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/os_client.py"
}

create_rollback_module() {
    echo "Creating rollback.py..."
    cat > "$INSTALL_DIR/rollback.py" << 'EOF'
import json
import logging
import sys
import time
from dataclasses import dataclass
from typing import Callable, List

log = logging.getLogger("mistral-os.rollback")

@dataclass
class CreatedResource:
    """A single resource created during a build, with its teardown callable."""
    resource_type: str   # human label e.g. "instance", "load_balancer"
    resource_id: str     # UUID
    resource_name: str   # display name
    teardown: Callable[[], None]  # zero-arg callable that deletes this resource

class BuildTransaction:
    """
    Context manager that records created resources and rolls them back
    in reverse order if the build raises an exception.
    """

    def __init__(self, dry_run: bool = False):
        self._registry: List[CreatedResource] = []
        self._dry_run = dry_run
        self._committed = False

    def register(
        self,
        resource_type: str,
        resource_id: str,
        resource_name: str,
        teardown: Callable[[], None],
    ) -> None:
        entry = CreatedResource(resource_type, resource_id, resource_name, teardown)
        self._registry.append(entry)
        log.info(f"TX registered {resource_type} '{resource_name}' ({resource_id})")

    def commit(self) -> None:
        """Mark the transaction successful — rollback will not run on exit."""
        self._committed = True
        log.info(f"TX committed — {len(self._registry)} resources retained.")

    def rollback(self) -> None:
        """Delete all registered resources in reverse creation order."""
        if not self._registry:
            return

        print("\n[rollback] Starting rollback...", file=sys.stderr)
        log.warning(f"TX rolling back {len(self._registry)} resources.")

        for resource in reversed(self._registry):
            label = f"{resource.resource_type} '{resource.resource_name}' ({resource.resource_id})"
            if self._dry_run:
                print(f"  [rollback][dry-run] would delete {label}", file=sys.stderr)
                continue
            try:
                print(f"  [rollback] Deleting {label}...", file=sys.stderr)
                resource.teardown()
                log.info(f"TX rolled back {label}")
            except Exception as exc:
                print(f"  [rollback] WARNING: failed to delete {label}: {exc}", file=sys.stderr)
                log.error(f"TX rollback failed for {label}: {exc}")

        print("[rollback] Rollback complete.", file=sys.stderr)

    def summary(self) -> str:
        return json.dumps([
            {"type": r.resource_type, "name": r.resource_name, "id": r.resource_id}
            for r in self._registry
        ], indent=2)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is not None and not self._committed:
            log.error(f"TX failed with {exc_type.__name__}: {exc_val}")
            self.rollback()
        return False  # re-raise the original exception after rollback
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/rollback.py"
}

create_transaction_module() {
    echo "Creating transaction.py..."
    cat > "$INSTALL_DIR/transaction.py" << 'EOF'
import threading
from rollback import BuildTransaction

# Active transaction — set by the agent before a build, cleared after
_active_tx: BuildTransaction = None
_tx_lock = threading.Lock()

def set_transaction(tx: BuildTransaction) -> None:
    global _active_tx
    _active_tx = tx

def get_transaction() -> BuildTransaction:
    return _active_tx

def register_resource(resource_type, resource_id, resource_name, teardown):
    """Thread-safe resource registration."""
    tx = get_transaction()
    if tx:
        with _tx_lock:
            tx.register(resource_type, resource_id, resource_name, teardown)
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/transaction.py"
}

create_quota_module() {
    echo "Creating quota.py..."
    cat > "$INSTALL_DIR/quota.py" << 'EOF'
import json
from os_client import get_conn

def get_compute_headroom() -> dict:
    """
    Returns current Nova quota usage and available headroom for the project.
    """
    conn = get_conn()
    limits = conn.compute.get_limits()
    absolute = limits.absolute

    limit_map = {item["name"]: item["value"] for item in absolute}

    return {
        "instances": {
            "limit": limit_map.get("maxTotalInstances", -1),
            "used":  limit_map.get("totalInstancesUsed", 0),
            "free":  limit_map.get("maxTotalInstances", 0) - limit_map.get("totalInstancesUsed", 0),
        },
        "vcpus": {
            "limit": limit_map.get("maxTotalCores", -1),
            "used":  limit_map.get("totalCoresUsed", 0),
            "free":  limit_map.get("maxTotalCores", 0) - limit_map.get("totalCoresUsed", 0),
        },
        "ram_mb": {
            "limit": limit_map.get("maxTotalRAMSize", -1),
            "used":  limit_map.get("totalRAMUsed", 0),
            "free":  limit_map.get("maxTotalRAMSize", 0) - limit_map.get("totalRAMUsed", 0),
        },
    }

def get_network_headroom() -> dict:
    """
    Returns Neutron quota usage for floating IPs and security groups.
    """
    conn  = get_conn()
    proj  = conn.current_project_id
    quota = conn.network.get_quota(proj, details=True)

    def _extract(resource_name: str) -> dict:
        val = getattr(quota, resource_name, None)
        if isinstance(val, dict):
            used  = val.get("used", 0)
            limit = val.get("limit", -1)
            return {"limit": limit, "used": used, "free": limit - used if limit >= 0 else -1}
        return {"limit": -1, "used": 0, "free": -1}

    return {
        "floating_ips":     _extract("floatingip"),
        "security_groups":  _extract("security_group"),
        "networks":         _extract("network"),
        "ports":            _extract("port"),
    }

def check_build_feasibility(
    instance_count: int,
    vcpus_per_instance: int,
    ram_mb_per_instance: int,
    floating_ip_count: int = 0,
    load_balancer_count: int = 0,
) -> dict:
    """
    Check whether the requested build fits within current project quota.
    """
    issues = []

    compute = get_compute_headroom()
    network = get_network_headroom()

    # Instances
    if compute["instances"]["free"] >= 0:
        if instance_count > compute["instances"]["free"]:
            issues.append(
                f"INSTANCES: need {instance_count}, only "
                f"{compute['instances']['free']} free "
                f"(limit {compute['instances']['limit']}, "
                f"used {compute['instances']['used']})"
            )

    # vCPUs
    total_vcpus = instance_count * vcpus_per_instance
    if compute["vcpus"]["free"] >= 0:
        if total_vcpus > compute["vcpus"]["free"]:
            issues.append(
                f"VCPUS: need {total_vcpus}, only "
                f"{compute['vcpus']['free']} free"
            )

    # RAM
    total_ram = instance_count * ram_mb_per_instance
    if compute["ram_mb"]["free"] >= 0:
        if total_ram > compute["ram_mb"]["free"]:
            issues.append(
                f"RAM: need {total_ram} MB, only "
                f"{compute['ram_mb']['free']} MB free"
            )

    # Floating IPs
    if floating_ip_count > 0 and network["floating_ips"]["free"] >= 0:
        if floating_ip_count > network["floating_ips"]["free"]:
            issues.append(
                f"FLOATING_IPS: need {floating_ip_count}, only "
                f"{network['floating_ips']['free']} free"
            )

    return {
        "feasible": len(issues) == 0,
        "issues":   issues,
        "headroom": {
            "compute": compute,
            "network": network,
        },
    }
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/quota.py"
}

create_cost_module() {
    echo "Creating cost.py..."
    cat > "$INSTALL_DIR/cost.py" << 'EOF'
import json
import os
from typing import Dict, List

# Load pricing from external file if available
_PRICING_FILE = os.environ.get(
    "MISTRAL_OS_PRICING_FILE",
    "/etc/mistral-openstack/pricing.json"
)

def _load_pricing() -> dict:
    try:
        with open(_PRICING_FILE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}

_pricing = _load_pricing()

# Default pricing table - update in /etc/mistral-openstack/pricing.json
FLAVOUR_COST_PER_HOUR: Dict[str, float] = _pricing.get("flavours", {
    "m1.tiny":    0.01,
    "m1.small":   0.03,
    "m1.medium":  0.06,
    "m1.large":   0.12,
    "m1.xlarge":  0.24,
})

FLOATING_IP_COST_PER_HOUR: float = _pricing.get("floating_ip_per_hour", 0.004)
LOAD_BALANCER_COST_PER_HOUR: float = _pricing.get("load_balancer_per_hour", 0.02)
VOLUME_COST_PER_GB_HOUR: float = _pricing.get("volume_per_gb_hour", 0.0001)

def estimate_build_cost(
    instance_specs: List[Dict],
    floating_ip_count: int = 0,
    load_balancer_count: int = 0,
    volume_gb: int = 0,
    duration_hours: float = 730,
) -> dict:
    """
    Estimate the cost of a proposed build over a given duration.
    """
    items = []
    total = 0.0

    for spec in instance_specs:
        flavour = spec.get("flavour_name", "unknown")
        rate    = FLAVOUR_COST_PER_HOUR.get(flavour)
        if rate is None:
            items.append({
                "resource": f"instance:{spec.get('name')}",
                "flavour":  flavour,
                "note":     "No pricing data — add to pricing.json",
            })
            continue
        cost = rate * duration_hours
        total += cost
        items.append({
            "resource":      f"instance:{spec.get('name')}",
            "flavour":       flavour,
            "rate_per_hour": rate,
            "hours":         duration_hours,
            "cost":          round(cost, 4),
        })

    if floating_ip_count:
        cost = FLOATING_IP_COST_PER_HOUR * floating_ip_count * duration_hours
        total += cost
        items.append({
            "resource": f"floating_ips x{floating_ip_count}",
            "rate_per_hour": FLOATING_IP_COST_PER_HOUR,
            "hours":   duration_hours,
            "cost":    round(cost, 4),
        })

    if load_balancer_count:
        cost = LOAD_BALANCER_COST_PER_HOUR * load_balancer_count * duration_hours
        total += cost
        items.append({
            "resource": f"load_balancers x{load_balancer_count}",
            "rate_per_hour": LOAD_BALANCER_COST_PER_HOUR,
            "hours":   duration_hours,
            "cost":    round(cost, 4),
        })

    if volume_gb:
        cost = VOLUME_COST_PER_GB_HOUR * volume_gb * duration_hours
        total += cost
        items.append({
            "resource": f"volumes:{volume_gb}GB",
            "rate_per_gb_hour": VOLUME_COST_PER_GB_HOUR,
            "hours":   duration_hours,
            "cost":    round(cost, 4),
        })

    return {
        "duration_hours": duration_hours,
        "items":          items,
        "total_estimated_cost": round(total, 4),
        "currency_note":  "Costs are estimates. Update pricing.json with actual rates.",
    }
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/cost.py"
}

create_tools_directory() {
    echo "Creating tools directory..."
    mkdir -p "$INSTALL_DIR/tools"
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/tools"
    
    # Create __init__.py first
    cat > "$INSTALL_DIR/tools/__init__.py" << 'EOF'
from tools.compute      import COMPUTE_TOOLS,      COMPUTE_HANDLERS
from tools.network      import NETWORK_TOOLS,       NETWORK_HANDLERS
from tools.loadbalancer import LOADBALANCER_TOOLS,  LOADBALANCER_HANDLERS
from tools.quota        import QUOTA_TOOLS,          QUOTA_HANDLERS

TOOLS = COMPUTE_TOOLS + NETWORK_TOOLS + LOADBALANCER_TOOLS + QUOTA_TOOLS

HANDLERS = {
    **COMPUTE_HANDLERS,
    **NETWORK_HANDLERS,
    **LOADBALANCER_HANDLERS,
    **QUOTA_HANDLERS,
}

# Tools that require operator confirmation before execution
DESTRUCTIVE_TOOLS = {
    "delete_server",
    "delete_load_balancer",
    "reboot_server",
}
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/tools/__init__.py"
}

# ── Uninstall Mode ───────────────────────────────────────────────────────────

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Uninstalling Mistral AI OpenStack core..."
    
    # Stop and disable services
    systemctl stop mistral-ai-agent || true
    systemctl disable mistral-ai-agent || true
    rm -f /etc/systemd/system/mistral-ai-agent.service
    systemctl daemon-reload
    
    # Kill any running processes
    pkill -f mistral-os || true
    
    # Remove CLI symlink
    rm -f /usr/local/bin/mistral-os
    
    # Remove directories
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
    
    # Remove service user
    if id "$SERVICE_USER" >/dev/null 2>&1; then
        userdel --remove "$SERVICE_USER" 2>/dev/null || true
    fi
    
    # Clean Redis data
    redis-cli FLUSHALL || true
    
    echo "Mistral AI OpenStack core uninstalled"
    exit 0
fi

# ── Main Installation ────────────────────────────────────────────────────────

echo "Installing Mistral AI OpenStack Integration - Core Agent"

# Root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Install system packages
install_pkg python3
install_pkg python3-venv
install_pkg python3-pip
install_pkg redis-server

# Create service user and directories
create_service_user
setup_directories

# Python environment and dependencies
create_virtual_environment

# Core Python modules
create_client_module
create_os_client_module
create_rollback_module
create_transaction_module
create_quota_module
create_cost_module

# Tools framework
create_tools_directory

echo ""
echo "✓ Mistral AI OpenStack core installation started"
echo ""
echo "Next steps:"
echo "  1. Run 14-mistral-ai-tools.sh to install the tool modules"
echo "  2. Run 15-mistral-ai-config.sh to configure credentials"
echo "  3. Set MISTRAL_API_KEY environment variable"
echo ""
echo "Installation directory: $INSTALL_DIR"
echo "Configuration directory: $CONFIG_DIR"
echo "Service user: $SERVICE_USER"