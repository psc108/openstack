import json
import time
import sys
import concurrent.futures
from typing import List, Dict, Any
from os_client import get_conn
from .resource_finder import find_image, find_flavor, find_network

# ── Tool Schemas ──────────────────────────────────────────────────────────────

COMPUTE_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_images",
            "description": "List available Glance images. Use this to find a valid image name before creating instances.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_flavours",
            "description": "List available Nova flavours (instance sizes). Use this to find a valid flavour before creating instances.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_servers",
            "description": "List all Nova compute instances with their current status.",
            "parameters": {
                "type": "object",
                "properties": {
                    "status_filter": {
                        "type": "string",
                        "description": "Optional: filter by status. Valid values: ACTIVE, ERROR, SHUTOFF, BUILD, DELETED.",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_server",
            "description": "Get detailed information about a specific server including its IP addresses.",
            "parameters": {
                "type": "object",
                "properties": {
                    "server_id": {
                        "type": "string",
                        "description": "Server name or UUID.",
                    }
                },
                "required": ["server_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_server",
            "description": (
                "Create a single Nova compute instance and wait for it to reach ACTIVE status. "
                "Returns the server's ID and assigned IP address. "
                "Call this once per instance — do not attempt to create multiple instances in a single call."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name":         {"type": "string", "description": "Instance name."},
                    "image_name":   {"type": "string", "description": "Glance image name (from list_images)."},
                    "flavour_name": {"type": "string", "description": "Nova flavour name (from list_flavours)."},
                    "network_name": {"type": "string", "description": "Neutron network name to attach to."},
                    "key_pair":     {"type": "string", "description": "Key pair name for SSH access. Optional."},
                    "security_groups": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "List of security group names. Optional.",
                    },
                    "user_data": {
                        "type": "string",
                        "description": "Cloud-init user data script (bash). Optional.",
                    },
                },
                "required": ["name", "image_name", "flavour_name", "network_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_servers_parallel",
            "description": (
                "Create multiple Nova instances concurrently. Use this instead of "
                "calling create_server repeatedly when creating 2 or more instances "
                "that share the same image, flavour, and network. "
                "All instances are started simultaneously and the call returns only "
                "when all have reached ACTIVE status. "
                "Returns a list of created server details including fixed IP addresses."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "server_specs": {
                        "type": "array",
                        "description": "List of instance specifications.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "name":         {"type": "string"},
                                "image_name":   {"type": "string"},
                                "flavour_name": {"type": "string"},
                                "network_name": {"type": "string"},
                                "key_pair":     {"type": "string"},
                                "security_groups": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                },
                            },
                            "required": ["name", "image_name", "flavour_name", "network_name"],
                        },
                    },
                    "max_workers": {
                        "type": "integer",
                        "description": "Maximum parallel creation threads. Default 5. Do not exceed 10.",
                    },
                },
                "required": ["server_specs"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "reboot_server",
            "description": "Reboot a Nova instance. Use SOFT unless the server is unresponsive.",
            "parameters": {
                "type": "object",
                "properties": {
                    "server_id":    {"type": "string", "description": "Server name or UUID."},
                    "reboot_type":  {"type": "string", "enum": ["SOFT", "HARD"], "description": "Reboot type."},
                },
                "required": ["server_id", "reboot_type"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "delete_server",
            "description": "Permanently delete a Nova instance. This is irreversible.",
            "parameters": {
                "type": "object",
                "properties": {
                    "server_id": {"type": "string", "description": "Server name or UUID."},
                },
                "required": ["server_id"],
            },
        },
    },
]

# ── Handler Functions ─────────────────────────────────────────────────────────

def list_images() -> str:
    conn = get_conn()
    images = [
        {"name": i.name, "id": i.id, "status": i.status, "size_gb": round((i.size or 0) / 1e9, 1)}
        for i in conn.image.images()
        if i.status == "active"
    ]
    return json.dumps(sorted(images, key=lambda x: x["name"]), indent=2)

def list_flavours() -> str:
    conn = get_conn()
    flavours = [
        {"name": f.name, "vcpus": f.vcpus, "ram_mb": f.ram, "disk_gb": f.disk}
        for f in conn.compute.flavors()
    ]
    return json.dumps(sorted(flavours, key=lambda x: x["ram_mb"]), indent=2)

def list_servers(status_filter: str = None) -> str:
    conn = get_conn()
    servers = list(conn.compute.servers())
    if status_filter:
        servers = [s for s in servers if s.status == status_filter.upper()]
    if not servers:
        return "No servers found."
    return json.dumps([
        {
            "name": s.name,
            "id": s.id,
            "status": s.status,
            "flavor": s.flavor.get("original_name", "unknown"),
            "addresses": s.addresses,
        }
        for s in servers
    ], indent=2)

def get_server(server_id: str) -> str:
    conn = get_conn()
    s = conn.compute.find_server(server_id, ignore_missing=False)
    # Extract first fixed IP across all networks
    ip = None
    for net_addrs in (s.addresses or {}).values():
        for addr in net_addrs:
            if addr.get("OS-EXT-IPS:type") == "fixed":
                ip = addr["addr"]
                break
        if ip:
            break
    return json.dumps({
        "name": s.name,
        "id": s.id,
        "status": s.status,
        "flavor": s.flavor.get("original_name"),
        "fixed_ip": ip,
        "addresses": s.addresses,
        "created_at": s.created_at,
        "hypervisor_host": s.hypervisor_hostname,
    }, indent=2)

def create_server(
    name: str,
    image_name: str,
    flavour_name: str,
    network_name: str,
    key_pair: str = None,
    security_groups: list = None,
    user_data: str = None,
) -> str:
    conn = get_conn()

    # Use centralized fuzzy finders
    try:
        image, matched_image = find_image(conn, image_name)
        flavour, matched_flavour = find_flavor(conn, flavour_name)
        network, matched_network = find_network(conn, network_name)
    except ValueError as e:
        return json.dumps({"error": str(e)})

    kwargs = dict(
        name=name,
        image_id=image.id,
        flavor_id=flavour.id,
        networks=[{"uuid": network.id}],
    )
    if key_pair:
        kwargs["key_name"] = key_pair
    if security_groups:
        kwargs["security_groups"] = [{"name": sg} for sg in security_groups]
    if user_data:
        import base64
        kwargs["user_data"] = base64.b64encode(user_data.encode()).decode()

    print(f"  [nova] Creating instance '{name}' (image: {matched_image}, flavour: {matched_flavour}, network: {matched_network})...")
    server = conn.compute.create_server(**kwargs)
    server = conn.compute.wait_for_server(server, status="ACTIVE", wait=300)

    # Resolve fixed IP
    ip = None
    for net_addrs in (server.addresses or {}).values():
        for addr in net_addrs:
            if addr.get("OS-EXT-IPS:type") == "fixed":
                ip = addr["addr"]
                break
        if ip:
            break

    print(f"  [nova] Instance '{name}' ACTIVE — IP: {ip}")
    
    # Register with active transaction if present
    from transaction import register_resource
    register_resource(
        resource_type="instance",
        resource_id=server.id,
        resource_name=server.name,
        teardown=lambda sid=server.id: _delete_server_by_id(sid),
    )
    
    return json.dumps({
        "name": server.name, 
        "id": server.id, 
        "status": server.status, 
        "fixed_ip": ip,
        "resources_used": {
            "image": matched_image,
            "flavour": matched_flavour, 
            "network": matched_network
        }
    })

def create_servers_parallel(
    server_specs: List[Dict[str, Any]],
    max_workers: int = 5,
) -> str:
    """
    Create multiple Nova instances concurrently and wait for all to reach ACTIVE.
    """
    results = []
    errors  = []

    def _create_one(spec: Dict[str, Any]) -> Dict[str, Any]:
        # Each thread gets its own connection
        import json as _json
        raw = create_server(**spec)
        return _json.loads(raw)

    print(f"  [nova] Creating {len(server_specs)} instances in parallel "
          f"(max_workers={max_workers})...")

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_spec = {
            executor.submit(_create_one, spec): spec
            for spec in server_specs
        }
        for future in concurrent.futures.as_completed(future_to_spec):
            spec = future_to_spec[future]
            try:
                result = future.result()
                results.append(result)
            except Exception as exc:
                errors.append({"name": spec.get("name"), "error": str(exc)})
                print(f"  [nova] ERROR creating '{spec.get('name')}': {exc}",
                      file=sys.stderr)

    if errors:
        # If any instance failed and rollback is active it will clean up.
        # Raise so the transaction sees the failure.
        raise RuntimeError(
            f"Parallel instance creation: {len(errors)} failure(s): "
            + json.dumps(errors)
        )

    print(f"  [nova] All {len(results)} instances ACTIVE.")
    return json.dumps(results, indent=2)

def reboot_server(server_id: str, reboot_type: str = "SOFT") -> str:
    conn = get_conn()
    s = conn.compute.find_server(server_id, ignore_missing=False)
    conn.compute.reboot_server(s.id, reboot_type=reboot_type)
    return f"Reboot ({reboot_type}) initiated for '{s.name}' ({s.id})."

def delete_server(server_id: str) -> str:
    conn = get_conn()
    s = conn.compute.find_server(server_id, ignore_missing=False)
    conn.compute.delete_server(s.id)
    print(f"  [nova] Deleted instance '{s.name}' ({s.id}).")
    return f"Instance '{s.name}' ({s.id}) deleted."

def _delete_server_by_id(server_id: str) -> None:
    """Internal teardown function for transaction rollback."""
    conn = get_conn()
    conn.compute.delete_server(server_id, ignore_missing=True)

# ── Handler Registry ──────────────────────────────────────────────────────────

COMPUTE_HANDLERS = {
    "list_images":           list_images,
    "list_flavours":         list_flavours,
    "list_servers":          list_servers,
    "get_server":            get_server,
    "create_server":         create_server,
    "create_servers_parallel": create_servers_parallel,
    "reboot_server":         reboot_server,
    "delete_server":         delete_server,
}
