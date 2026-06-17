#!/usr/bin/env bash
# =============================================================================
# 17-mistral-ai-quota.sh — Mistral AI Quota and Cost Tools Installation
# =============================================================================
# Installs quota checking and cost estimation tools for the Mistral AI OpenStack
# agent. Provides pre-build validation across Nova/Neutron/Octavia with detailed
# headroom reporting and configurable cost estimation with itemized breakdowns.
#
# What it installs:
#   - Quota and cost tools module (tools/quota.py)
#   - Pre-build quota validation across all OpenStack services
#   - Detailed quota headroom reporting with usage statistics
#   - Cost estimation with configurable pricing (pricing.json)
#   - Flavour coverage validation for fail-fast approach
#   - Resource feasibility checking before builds
#   - Default pricing configuration with GBP rates
#
# Tool Functions:
#   - check_quota_headroom, get_quota_details
#   - estimate_cost, get_pricing_info, validate_flavour_costs
#
# Configuration:
#   - /etc/mistral-openstack/pricing.json (updateable pricing rates)
#   - Flavour rates, floating IP, load balancer, volume costs
#   - Currency and duration settings
#
# Prerequisites:
#   - 13-mistral-ai-core.sh (core agent installation)
#   - OpenStack services for quota checking (Nova, Neutron, Octavia)
#
# Usage:
#   sudo bash 17-mistral-ai-quota.sh           # Install quota tools
#   sudo bash 17-mistral-ai-quota.sh --uninstall # Remove quota tools
#
# Post-install: Update /etc/mistral-openstack/pricing.json with actual rates
#
# Re-run safe: Yes (module replacement approach)
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/mistral-openstack"
CONFIG_DIR="/etc/mistral-openstack"
SERVICE_USER="mistral"

# ── Functions ─────────────────────────────────────────────────────────────────

create_quota_tools() {
    echo "Creating tools/quota.py..."
    cat > "$INSTALL_DIR/tools/quota.py" << 'EOF'
import json
from quota import check_build_feasibility, get_compute_headroom, get_network_headroom
from cost import estimate_build_cost

# ── Tool Schemas ──────────────────────────────────────────────────────────────

QUOTA_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "check_quota_headroom",
            "description": (
                "Check current project quota usage and available headroom across Nova, "
                "Neutron, and Octavia before starting a build. "
                "Call this before any large create operation to verify the build will not "
                "fail partway through due to quota exhaustion."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "instance_count":        {"type": "integer", "description": "Number of instances to create."},
                    "vcpus_per_instance":    {"type": "integer", "description": "vCPUs per instance (from flavour)."},
                    "ram_mb_per_instance":   {"type": "integer", "description": "RAM in MB per instance (from flavour)."},
                    "floating_ip_count":     {"type": "integer", "description": "Number of floating IPs needed. Default 0."},
                    "load_balancer_count":   {"type": "integer", "description": "Number of load balancers to create. Default 0."},
                },
                "required": ["instance_count", "vcpus_per_instance", "ram_mb_per_instance"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_quota_details",
            "description": (
                "Get detailed quota information for all OpenStack services. "
                "Useful for understanding current resource usage and limits."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "estimate_cost",
            "description": (
                "Estimate the cost of a proposed build based on the local pricing table. "
                "Returns itemised and total cost for the specified duration. "
                "Call this before large builds so the operator can review costs."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "instance_specs": {
                        "type": "array",
                        "description": "List of instance specs with name and flavour_name.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "name":         {"type": "string"},
                                "flavour_name": {"type": "string"},
                            },
                            "required": ["name", "flavour_name"],
                        },
                    },
                    "floating_ip_count":   {"type": "integer", "description": "Number of floating IPs."},
                    "load_balancer_count": {"type": "integer", "description": "Number of load balancers."},
                    "volume_gb":           {"type": "integer", "description": "Total Cinder volume in GB."},
                    "duration_hours":      {
                        "type": "number",
                        "description": "Duration to estimate over in hours. Default 730 (one month).",
                    },
                },
                "required": ["instance_specs"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_pricing_info",
            "description": (
                "Get current pricing configuration including flavour rates and "
                "other resource costs. Useful for understanding cost calculation basis."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "validate_flavour_costs",
            "description": (
                "Check which flavours have pricing data and which are missing. "
                "Helps identify pricing gaps before cost estimation."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
]

# ── Handler Functions ─────────────────────────────────────────────────────────

def check_quota_headroom(
    instance_count: int,
    vcpus_per_instance: int,
    ram_mb_per_instance: int,
    floating_ip_count: int = 0,
    load_balancer_count: int = 0,
) -> str:
    result = check_build_feasibility(
        instance_count=instance_count,
        vcpus_per_instance=vcpus_per_instance,
        ram_mb_per_instance=ram_mb_per_instance,
        floating_ip_count=floating_ip_count,
        load_balancer_count=load_balancer_count,
    )
    if not result["feasible"]:
        result["recommendation"] = (
            "Build will fail due to quota limits. "
            "Reduce instance count or contact your administrator to raise quotas."
        )
    else:
        result["recommendation"] = "Build is feasible within current quota limits."
    
    return json.dumps(result, indent=2)

def get_quota_details() -> str:
    compute_headroom = get_compute_headroom()
    network_headroom = get_network_headroom()
    
    # Try to get Octavia quota if available
    octavia_headroom = {}
    try:
        from os_client import get_conn
        conn = get_conn()
        proj = conn.current_project_id
        quota = conn.load_balancer.get_quota(proj)
        octavia_headroom = {
            "load_balancers": {"limit": quota.load_balancer},
            "listeners":      {"limit": quota.listener},
            "pools":          {"limit": quota.pool},
            "members":        {"limit": quota.member},
        }
    except Exception as exc:
        octavia_headroom = {"note": f"Octavia quota unavailable: {exc}"}
    
    return json.dumps({
        "compute": compute_headroom,
        "network": network_headroom,
        "load_balancer": octavia_headroom,
    }, indent=2)

def estimate_cost(
    instance_specs: list,
    floating_ip_count: int = 0,
    load_balancer_count: int = 0,
    volume_gb: int = 0,
    duration_hours: float = 730,
) -> str:
    result = estimate_build_cost(
        instance_specs=instance_specs,
        floating_ip_count=floating_ip_count,
        load_balancer_count=load_balancer_count,
        volume_gb=volume_gb,
        duration_hours=duration_hours,
    )
    return json.dumps(result, indent=2)

def get_pricing_info() -> str:
    from cost import (
        FLAVOUR_COST_PER_HOUR,
        FLOATING_IP_COST_PER_HOUR,
        LOAD_BALANCER_COST_PER_HOUR,
        VOLUME_COST_PER_GB_HOUR
    )
    
    return json.dumps({
        "flavour_rates": FLAVOUR_COST_PER_HOUR,
        "floating_ip_per_hour": FLOATING_IP_COST_PER_HOUR,
        "load_balancer_per_hour": LOAD_BALANCER_COST_PER_HOUR,
        "volume_per_gb_per_hour": VOLUME_COST_PER_GB_HOUR,
        "default_duration_hours": 730,
        "note": "Rates can be updated in /etc/mistral-openstack/pricing.json",
    }, indent=2)

def validate_flavour_costs() -> str:
    from cost import FLAVOUR_COST_PER_HOUR
    from os_client import get_conn
    
    conn = get_conn()
    flavours = list(conn.compute.flavors())
    
    flavours_with_pricing = []
    flavours_without_pricing = []
    
    for flavour in flavours:
        if flavour.name in FLAVOUR_COST_PER_HOUR:
            flavours_with_pricing.append({
                "name": flavour.name,
                "vcpus": flavour.vcpus,
                "ram_mb": flavour.ram,
                "disk_gb": flavour.disk,
                "cost_per_hour": FLAVOUR_COST_PER_HOUR[flavour.name],
            })
        else:
            flavours_without_pricing.append({
                "name": flavour.name,
                "vcpus": flavour.vcpus,
                "ram_mb": flavour.ram,
                "disk_gb": flavour.disk,
            })
    
    return json.dumps({
        "flavours_with_pricing": sorted(flavours_with_pricing, key=lambda x: x["name"]),
        "flavours_without_pricing": sorted(flavours_without_pricing, key=lambda x: x["name"]),
        "pricing_coverage": f"{len(flavours_with_pricing)}/{len(flavours)} flavours have pricing data",
        "recommendation": (
            "Add missing flavours to /etc/mistral-openstack/pricing.json for accurate cost estimates"
            if flavours_without_pricing else 
            "All flavours have pricing data"
        ),
    }, indent=2)

# ── Handler Registry ──────────────────────────────────────────────────────────

QUOTA_HANDLERS = {
    "check_quota_headroom":   check_quota_headroom,
    "get_quota_details":      get_quota_details,
    "estimate_cost":          estimate_cost,
    "get_pricing_info":       get_pricing_info,
    "validate_flavour_costs": validate_flavour_costs,
}
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/tools/quota.py"
}

create_default_pricing_file() {
    echo "Creating default pricing configuration..."
    cat > "$CONFIG_DIR/pricing.json" << 'EOF'
{
  "flavours": {
    "m1.tiny":   0.01,
    "m1.small":  0.03,
    "m1.medium": 0.06,
    "m1.large":  0.12,
    "m1.xlarge": 0.24,
    "m2.tiny":   0.015,
    "m2.small":  0.035,
    "m2.medium": 0.07,
    "m2.large":  0.14,
    "m2.xlarge": 0.28,
    "c1.small":  0.05,
    "c1.medium": 0.10,
    "c1.large":  0.20,
    "c1.xlarge": 0.40,
    "r1.small":  0.08,
    "r1.medium": 0.16,
    "r1.large":  0.32,
    "r1.xlarge": 0.64
  },
  "floating_ip_per_hour": 0.004,
  "load_balancer_per_hour": 0.02,
  "volume_per_gb_hour": 0.0001,
  "currency": "GBP",
  "note": "Sample pricing - update with your actual rates"
}
EOF
    chown root:root "$CONFIG_DIR/pricing.json"
    chmod 644 "$CONFIG_DIR/pricing.json"
}

# ── Uninstall Mode ───────────────────────────────────────────────────────────

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Removing Mistral AI quota and cost tools..."
    
    # Remove quota tools module
    rm -f "$INSTALL_DIR/tools/quota.py"
    
    # Remove pricing configuration
    rm -f "$CONFIG_DIR/pricing.json"
    
    # Remove any quota/cost-related logs or cache
    find "$INSTALL_DIR" -name "*quota*" -type f -delete 2>/dev/null || true
    find "$INSTALL_DIR" -name "*cost*" -type f -delete 2>/dev/null || true
    find "$INSTALL_DIR" -name "*pricing*" -type f -delete 2>/dev/null || true
    
    echo "Mistral AI quota and cost tools removed"
    exit 0
fi

# ── Main Installation ────────────────────────────────────────────────────────

echo "Installing Mistral AI Quota and Cost Tools..."

# Check if core installation exists
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Error: Core installation not found at $INSTALL_DIR"
    echo "Please run 13-mistral-ai-core.sh first"
    exit 1
fi

# Root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Create quota and cost tools
create_quota_tools

# Create default pricing configuration if it doesn't exist
if [[ ! -f "$CONFIG_DIR/pricing.json" ]]; then
    create_default_pricing_file
fi

echo ""
echo "✓ Mistral AI Quota and Cost Tools installed"
echo ""
echo "Features added:"
echo "  • Pre-build quota validation across Nova/Neutron/Octavia"
echo "  • Detailed quota headroom reporting"
echo "  • Cost estimation with itemised breakdown"
echo "  • Pricing configuration management"
echo "  • Flavour cost coverage validation"
echo ""
echo "Configuration:"
echo "  • Pricing file: $CONFIG_DIR/pricing.json"
echo "  • Update pricing.json with your actual rates"
echo ""
echo "Next: Run 18-mistral-ai-agent.sh for the agent loop and CLI"