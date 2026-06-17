#!/usr/bin/env bash
# =============================================================================
# 15-mistral-ai-network.sh — Mistral AI Network Tools (Neutron) Installation
# =============================================================================
# Installs Neutron network management tools for the Mistral AI OpenStack agent.
# Provides comprehensive networking support including floating IP management,
# security groups, and port discovery with transaction rollback integration.
#
# What it installs:
#   - Neutron network tools module (tools/network.py)
#   - Network and subnet discovery functions
#   - Security group management
#   - Comprehensive floating IP lifecycle (create, assign, associate, delete)
#   - Port management with device owner filtering
#   - Transaction rollback support for network resources
#   - Rich Mistral function schemas for AI integration
#
# Tool Functions:
#   - list_networks, list_subnets, list_security_groups, list_ports
#   - list_floating_ips, create_floating_ip, assign_floating_ip
#   - associate_floating_ip, disassociate_floating_ip, delete_floating_ip
#
# Prerequisites:
#   - 13-mistral-ai-core.sh (core agent installation)
#   - 06-neutron.sh (Neutron networking service)
#
# Usage:
#   sudo bash 15-mistral-ai-network.sh           # Install network tools
#   sudo bash 15-mistral-ai-network.sh --uninstall # Remove network tools
#
# Re-run safe: Yes (module replacement approach)
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/mistral-openstack"
SERVICE_USER="mistral"

# ── Functions ─────────────────────────────────────────────────────────────────

create_network_tools() {
    echo "Creating tools/network.py..."
    cat > "$INSTALL_DIR/tools/network.py" << 'EOF'
import json
from os_client import get_conn

# ── Tool Schemas ──────────────────────────────────────────────────────────────

NETWORK_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_networks",
            "description": "List available Neutron networks. Use this to find a valid network name before creating instances or load balancers.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_subnets",
            "description": "List subnets, optionally filtered by network name. Returns subnet IDs needed for load balancer creation.",
            "parameters": {
                "type": "object",
                "properties": {
                    "network_name": {
                        "type": "string",
                        "description": "Optional: filter subnets by network name.",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_security_groups",
            "description": "List available Neutron security groups.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_ports",
            "description": "List Neutron ports, optionally filtered by network or device type.",
            "parameters": {
                "type": "object",
                "properties": {
                    "network_name": {
                        "type": "string",
                        "description": "Optional: filter ports by network name.",
                    },
                    "device_owner": {
                        "type": "string",
                        "description": "Optional: filter by device owner (e.g. 'compute:nova', 'neutron:LOADBALANCERV2').",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_floating_ips",
            "description": "List floating IPs with their status and associations.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "assign_floating_ip",
            "description": (
                "Allocate a floating IP from an external network and associate it with a "
                "Neutron port (typically a load balancer VIP port or instance port). "
                "Returns the allocated floating IP address."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "external_network_name": {
                        "type": "string",
                        "description": "Name of the external/public network to allocate the floating IP from.",
                    },
                    "port_id": {
                        "type": "string",
                        "description": "The Neutron port ID to associate the floating IP with.",
                    },
                },
                "required": ["external_network_name", "port_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_floating_ip",
            "description": (
                "Allocate a floating IP from an external network without associating it to any port. "
                "Use assign_floating_ip if you want to allocate and associate in one step."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "external_network_name": {
                        "type": "string",
                        "description": "Name of the external/public network to allocate the floating IP from.",
                    },
                    "description": {
                        "type": "string",
                        "description": "Optional description for the floating IP.",
                    },
                },
                "required": ["external_network_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "associate_floating_ip",
            "description": "Associate an existing floating IP with a port.",
            "parameters": {
                "type": "object",
                "properties": {
                    "floating_ip": {
                        "type": "string",
                        "description": "Floating IP address or floating IP ID.",
                    },
                    "port_id": {
                        "type": "string",
                        "description": "The Neutron port ID to associate with.",
                    },
                },
                "required": ["floating_ip", "port_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "disassociate_floating_ip",
            "description": "Remove a floating IP association from its current port.",
            "parameters": {
                "type": "object",
                "properties": {
                    "floating_ip": {
                        "type": "string",
                        "description": "Floating IP address or floating IP ID.",
                    },
                },
                "required": ["floating_ip"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "delete_floating_ip",
            "description": "Delete a floating IP and return it to the pool. This is irreversible.",
            "parameters": {
                "type": "object",
                "properties": {
                    "floating_ip": {
                        "type": "string",
                        "description": "Floating IP address or floating IP ID.",
                    },
                },
                "required": ["floating_ip"],
            },
        },
    },
]

# ── Handler Functions ─────────────────────────────────────────────────────────

def list_networks() -> str:
    conn = get_conn()
    nets = [
        {
            "name": n.name,
            "id": n.id,
            "status": n.status,
            "external": n.is_router_external,
            "shared": n.is_shared,
            "subnets": n.subnet_ids,
        }
        for n in conn.network.networks()
    ]
    return json.dumps(sorted(nets, key=lambda x: x["name"]), indent=2)

def list_subnets(network_name: str = None) -> str:
    conn = get_conn()
    subnets = list(conn.network.subnets())
    if network_name:
        net = conn.network.find_network(network_name, ignore_missing=False)
        subnets = [s for s in subnets if s.network_id == net.id]
    return json.dumps([
        {
            "name": s.name, 
            "id": s.id, 
            "cidr": s.cidr, 
            "network_id": s.network_id,
            "gateway_ip": s.gateway_ip,
            "dns_nameservers": s.dns_nameservers,
        }
        for s in subnets
    ], indent=2)

def list_security_groups() -> str:
    conn = get_conn()
    sgs = [
        {
            "name": sg.name, 
            "id": sg.id, 
            "description": sg.description,
            "rules_count": len(sg.security_group_rules or []),
        }
        for sg in conn.network.security_groups()
    ]
    return json.dumps(sorted(sgs, key=lambda x: x["name"]), indent=2)

def list_ports(network_name: str = None, device_owner: str = None) -> str:
    conn = get_conn()
    ports = list(conn.network.ports())
    
    if network_name:
        net = conn.network.find_network(network_name, ignore_missing=False)
        ports = [p for p in ports if p.network_id == net.id]
    
    if device_owner:
        ports = [p for p in ports if device_owner.lower() in (p.device_owner or "").lower()]
    
    return json.dumps([
        {
            "id": p.id,
            "name": p.name or "",
            "status": p.status,
            "device_owner": p.device_owner,
            "device_id": p.device_id,
            "fixed_ips": p.fixed_ips,
            "network_id": p.network_id,
        }
        for p in ports
    ], indent=2)

def list_floating_ips() -> str:
    conn = get_conn()
    fips = [
        {
            "floating_ip": fip.floating_ip_address,
            "id": fip.id,
            "status": fip.status,
            "port_id": fip.port_id,
            "fixed_ip": fip.fixed_ip_address,
            "floating_network_id": fip.floating_network_id,
            "description": fip.description,
        }
        for fip in conn.network.ips()
    ]
    return json.dumps(sorted(fips, key=lambda x: x["floating_ip"]), indent=2)

def assign_floating_ip(external_network_name: str, port_id: str) -> str:
    conn = get_conn()
    ext_net = conn.network.find_network(external_network_name, ignore_missing=False)
    fip = conn.network.create_ip(
        floating_network_id=ext_net.id,
        port_id=port_id,
    )
    print(f"  [neutron] Floating IP {fip.floating_ip_address} → port {port_id}")
    
    # Register with active transaction if present
    from transaction import register_resource
    register_resource(
        resource_type="floating_ip",
        resource_id=fip.id,
        resource_name=fip.floating_ip_address,
        teardown=lambda fid=fip.id: _delete_fip_by_id(fid),
    )
    
    return json.dumps({
        "floating_ip": fip.floating_ip_address,
        "floating_ip_id": fip.id,
        "port_id": port_id,
        "status": fip.status,
    })

def create_floating_ip(external_network_name: str, description: str = "") -> str:
    conn = get_conn()
    ext_net = conn.network.find_network(external_network_name, ignore_missing=False)
    fip = conn.network.create_ip(
        floating_network_id=ext_net.id,
        description=description,
    )
    print(f"  [neutron] Created floating IP {fip.floating_ip_address}")
    
    # Register with active transaction if present
    from transaction import register_resource
    register_resource(
        resource_type="floating_ip",
        resource_id=fip.id,
        resource_name=fip.floating_ip_address,
        teardown=lambda fid=fip.id: _delete_fip_by_id(fid),
    )
    
    return json.dumps({
        "floating_ip": fip.floating_ip_address,
        "floating_ip_id": fip.id,
        "status": fip.status,
        "description": description,
    })

def associate_floating_ip(floating_ip: str, port_id: str) -> str:
    conn = get_conn()
    # Find floating IP by address or ID
    try:
        fip = conn.network.find_ip(floating_ip, ignore_missing=False)
    except Exception:
        # Try by floating IP address
        fips = [f for f in conn.network.ips() if f.floating_ip_address == floating_ip]
        if not fips:
            return f"Floating IP '{floating_ip}' not found"
        fip = fips[0]
    
    # Update the floating IP to associate with the port
    conn.network.update_ip(fip.id, port_id=port_id)
    print(f"  [neutron] Associated floating IP {fip.floating_ip_address} → port {port_id}")
    
    return json.dumps({
        "floating_ip": fip.floating_ip_address,
        "floating_ip_id": fip.id,
        "port_id": port_id,
        "status": "ACTIVE",
    })

def disassociate_floating_ip(floating_ip: str) -> str:
    conn = get_conn()
    # Find floating IP by address or ID
    try:
        fip = conn.network.find_ip(floating_ip, ignore_missing=False)
    except Exception:
        # Try by floating IP address
        fips = [f for f in conn.network.ips() if f.floating_ip_address == floating_ip]
        if not fips:
            return f"Floating IP '{floating_ip}' not found"
        fip = fips[0]
    
    # Update the floating IP to remove port association
    conn.network.update_ip(fip.id, port_id=None)
    print(f"  [neutron] Disassociated floating IP {fip.floating_ip_address}")
    
    return json.dumps({
        "floating_ip": fip.floating_ip_address,
        "floating_ip_id": fip.id,
        "port_id": None,
        "status": "DOWN",
    })

def delete_floating_ip(floating_ip: str) -> str:
    conn = get_conn()
    # Find floating IP by address or ID
    try:
        fip = conn.network.find_ip(floating_ip, ignore_missing=False)
    except Exception:
        # Try by floating IP address
        fips = [f for f in conn.network.ips() if f.floating_ip_address == floating_ip]
        if not fips:
            return f"Floating IP '{floating_ip}' not found"
        fip = fips[0]
    
    conn.network.delete_ip(fip.id)
    print(f"  [neutron] Deleted floating IP {fip.floating_ip_address} ({fip.id})")
    return f"Floating IP '{fip.floating_ip_address}' ({fip.id}) deleted."

def _delete_fip_by_id(fip_id: str) -> None:
    """Internal teardown function for transaction rollback."""
    conn = get_conn()
    conn.network.delete_ip(fip_id, ignore_missing=True)

# ── Handler Registry ──────────────────────────────────────────────────────────

NETWORK_HANDLERS = {
    "list_networks":           list_networks,
    "list_subnets":            list_subnets,
    "list_security_groups":    list_security_groups,
    "list_ports":              list_ports,
    "list_floating_ips":       list_floating_ips,
    "assign_floating_ip":      assign_floating_ip,
    "create_floating_ip":      create_floating_ip,
    "associate_floating_ip":   associate_floating_ip,
    "disassociate_floating_ip": disassociate_floating_ip,
    "delete_floating_ip":      delete_floating_ip,
}
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/tools/network.py"
}

# ── Uninstall Mode ───────────────────────────────────────────────────────────

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Removing Mistral AI network tools..."
    
    # Remove network tools module
    rm -f "$INSTALL_DIR/tools/network.py"
    
    # Remove any network-related logs or cache
    find "$INSTALL_DIR" -name "*network*" -type f -delete 2>/dev/null || true
    
    echo "Mistral AI network tools removed"
    exit 0
fi

# ── Main Installation ────────────────────────────────────────────────────────

echo "Installing Mistral AI Network Tools (Neutron)..."

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

# Create network tools
create_network_tools

echo ""
echo "✓ Mistral AI Network Tools installed"
echo ""
echo "Features added:"
echo "  • Network and subnet discovery"
echo "  • Security group listing"
echo "  • Port management and filtering"
echo "  • Floating IP management (create, assign, associate, delete)"
echo "  • Transaction rollback integration"
echo ""
echo "Next: Run 16-mistral-ai-loadbalancer.sh for load balancer tools"