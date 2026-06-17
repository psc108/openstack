import json
import time
from os_client import get_conn
from .resource_finder import find_subnet

# ── Tool Schemas ──────────────────────────────────────────────────────────────

LOADBALANCER_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_load_balancers",
            "description": "List existing Octavia load balancers with their status and VIP addresses.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_load_balancer",
            "description": "Get full details of a load balancer including its VIP address and VIP port ID.",
            "parameters": {
                "type": "object",
                "properties": {
                    "lb_id": {"type": "string", "description": "Load balancer UUID or name."},
                },
                "required": ["lb_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_load_balancer",
            "description": (
                "Create an Octavia load balancer on a given subnet. "
                "After calling this you MUST call wait_for_load_balancer before any further "
                "load balancer operations. Returns the load balancer ID and VIP port ID."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name":        {"type": "string", "description": "Load balancer name."},
                    "subnet_name": {"type": "string", "description": "Subnet name the VIP will be placed on (from list_subnets)."},
                    "description": {"type": "string", "description": "Optional description."},
                },
                "required": ["name", "subnet_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "wait_for_load_balancer",
            "description": (
                "Wait for a load balancer to reach ACTIVE provisioning status. "
                "MUST be called after create_load_balancer, create_lb_listener, "
                "create_lb_pool, create_health_monitor, and each create_lb_member call. "
                "Octavia operations are asynchronous and will fail if you proceed without waiting."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "lb_id": {"type": "string", "description": "Load balancer UUID (from create_load_balancer)."},
                },
                "required": ["lb_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_lb_listener",
            "description": (
                "Create a listener on a load balancer. A listener defines the protocol and port "
                "the load balancer accepts traffic on. Call wait_for_load_balancer after this."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name":     {"type": "string", "description": "Listener name."},
                    "lb_id":    {"type": "string", "description": "Load balancer UUID."},
                    "protocol": {
                        "type": "string",
                        "enum": ["HTTP", "HTTPS", "TCP", "TERMINATED_HTTPS"],
                        "description": "Listener protocol.",
                    },
                    "port": {"type": "integer", "description": "Port number the listener accepts traffic on (e.g. 80, 443)."},
                },
                "required": ["name", "lb_id", "protocol", "port"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_lb_pool",
            "description": (
                "Create a backend pool on a listener. The pool holds the member instances. "
                "Call wait_for_load_balancer after this."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name":        {"type": "string", "description": "Pool name."},
                    "listener_id": {"type": "string", "description": "Listener UUID (from create_lb_listener)."},
                    "protocol":    {
                        "type": "string",
                        "enum": ["HTTP", "HTTPS", "TCP"],
                        "description": "Pool protocol — must match listener protocol for HTTP/HTTPS.",
                    },
                    "algorithm": {
                        "type": "string",
                        "enum": ["ROUND_ROBIN", "LEAST_CONNECTIONS", "SOURCE_IP"],
                        "description": "Load balancing algorithm. ROUND_ROBIN is the standard default.",
                    },
                },
                "required": ["name", "listener_id", "protocol", "algorithm"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_health_monitor",
            "description": (
                "Create a health monitor on a pool. The health monitor periodically checks "
                "backend members and removes unresponsive ones from rotation. "
                "Strongly recommended for all production pools. "
                "Call wait_for_load_balancer after this."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "pool_id":     {"type": "string", "description": "Pool UUID (from create_lb_pool)."},
                    "type":        {
                        "type": "string",
                        "enum": ["HTTP", "HTTPS", "TCP", "PING"],
                        "description": "Health check type. Use HTTP for web services.",
                    },
                    "delay":       {"type": "integer", "description": "Seconds between health checks. Default: 10."},
                    "timeout":     {"type": "integer", "description": "Seconds before a check times out. Default: 5."},
                    "max_retries": {"type": "integer", "description": "Failures before marking member down. Default: 3."},
                    "url_path":    {"type": "string", "description": "URL path for HTTP checks (e.g. /healthcheck). Default: /."},
                },
                "required": ["pool_id", "type"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_lb_member",
            "description": (
                "Add a backend instance as a member of a load balancer pool. "
                "Provide the instance's fixed IP address and the port it serves traffic on. "
                "Call wait_for_load_balancer after each member addition."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "pool_id":    {"type": "string", "description": "Pool UUID (from create_lb_pool)."},
                    "name":       {"type": "string", "description": "Member name (typically the instance name)."},
                    "address":    {"type": "string", "description": "Fixed IP address of the backend instance."},
                    "port":       {"type": "integer", "description": "Port the instance serves traffic on (e.g. 80)."},
                    "subnet_name": {"type": "string", "description": "Subnet name the instance is on (from list_subnets)."},
                    "weight":     {"type": "integer", "description": "Member weight for weighted algorithms. Default: 1."},
                },
                "required": ["pool_id", "name", "address", "port", "subnet_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_lb_listeners",
            "description": "List listeners for a specific load balancer.",
            "parameters": {
                "type": "object",
                "properties": {
                    "lb_id": {"type": "string", "description": "Load balancer UUID."},
                },
                "required": ["lb_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_lb_pools",
            "description": "List pools for a specific listener or load balancer.",
            "parameters": {
                "type": "object",
                "properties": {
                    "listener_id": {"type": "string", "description": "Optional: listener UUID to filter pools."},
                    "lb_id":       {"type": "string", "description": "Optional: load balancer UUID to filter pools."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_lb_members",
            "description": "List members in a specific pool with their health status.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pool_id": {"type": "string", "description": "Pool UUID."},
                },
                "required": ["pool_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "delete_load_balancer",
            "description": "Delete a load balancer and all its child resources (cascade delete). Irreversible.",
            "parameters": {
                "type": "object",
                "properties": {
                    "lb_id": {"type": "string", "description": "Load balancer UUID or name."},
                },
                "required": ["lb_id"],
            },
        },
    },
]

# ── Helper Functions ──────────────────────────────────────────────────────────

def _poll_lb_active(conn, lb_id: str, timeout: int = 600, interval: int = 5):
    """
    Block until the load balancer provisioning_status is ACTIVE or ERROR.
    Raises on ERROR or timeout.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        lb = conn.load_balancer.get_load_balancer(lb_id)
        status = lb.provisioning_status
        if status == "ACTIVE":
            return lb
        if status == "ERROR":
            raise RuntimeError(f"Load balancer {lb_id} entered ERROR state.")
        time.sleep(interval)
    raise TimeoutError(f"Load balancer {lb_id} did not become ACTIVE within {timeout}s.")

# ── Handler Functions ─────────────────────────────────────────────────────────

def list_load_balancers() -> str:
    conn = get_conn()
    lbs = [
        {
            "name": lb.name,
            "id": lb.id,
            "provisioning_status": lb.provisioning_status,
            "operating_status": lb.operating_status,
            "vip_address": lb.vip_address,
            "vip_port_id": lb.vip_port_id,
            "listeners": len(lb.listeners or []),
        }
        for lb in conn.load_balancer.load_balancers()
    ]
    return json.dumps(lbs, indent=2) if lbs else "No load balancers found."

def get_load_balancer(lb_id: str) -> str:
    conn = get_conn()
    lb = conn.load_balancer.find_load_balancer(lb_id, ignore_missing=False)
    return json.dumps({
        "name": lb.name,
        "id": lb.id,
        "provisioning_status": lb.provisioning_status,
        "operating_status": lb.operating_status,
        "vip_address": lb.vip_address,
        "vip_port_id": lb.vip_port_id,
        "description": lb.description,
        "listeners": [l.id for l in (lb.listeners or [])],
        "created_at": lb.created_at,
        "updated_at": lb.updated_at,
    })

def create_load_balancer(name: str, subnet_name: str, description: str = "") -> str:
    conn = get_conn()
    
    # Use centralized fuzzy finder
    try:
        subnet, matched_name = find_subnet(conn, subnet_name)
    except ValueError as e:
        return json.dumps({"error": str(e)})
    
    print(f"  [octavia] Creating load balancer '{name}' on subnet '{matched_name}'...")
    lb = conn.load_balancer.create_load_balancer(
        name=name,
        vip_subnet_id=subnet.id,
        description=description,
    )
    
    # Register with active transaction if present
    from transaction import register_resource
    register_resource(
        resource_type="load_balancer",
        resource_id=lb.id,
        resource_name=name,
        teardown=lambda lid=lb.id: _delete_lb_by_id(lid),
    )
    
    return json.dumps({
        "lb_id": lb.id,
        "name": lb.name,
        "vip_address": lb.vip_address,
        "vip_port_id": lb.vip_port_id,
        "provisioning_status": lb.provisioning_status,
        "subnet_used": matched_name,
        "note": "Call wait_for_load_balancer before proceeding.",
    })

def wait_for_load_balancer(lb_id: str) -> str:
    conn = get_conn()
    print(f"  [octavia] Waiting for load balancer {lb_id} to become ACTIVE...")
    lb = _poll_lb_active(conn, lb_id)
    print(f"  [octavia] Load balancer {lb_id} is ACTIVE.")
    return json.dumps({
        "lb_id": lb.id,
        "provisioning_status": lb.provisioning_status,
        "operating_status": lb.operating_status,
        "vip_address": lb.vip_address,
        "vip_port_id": lb.vip_port_id,
    })

def create_lb_listener(name: str, lb_id: str, protocol: str, port: int) -> str:
    conn = get_conn()
    print(f"  [octavia] Creating listener '{name}' ({protocol}:{port})...")
    listener = conn.load_balancer.create_listener(
        name=name,
        load_balancer_id=lb_id,
        protocol=protocol,
        protocol_port=port,
    )
    return json.dumps({
        "listener_id": listener.id,
        "name": listener.name,
        "protocol": listener.protocol,
        "port": listener.protocol_port,
        "note": "Call wait_for_load_balancer before proceeding.",
    })

def create_lb_pool(name: str, listener_id: str, protocol: str, algorithm: str) -> str:
    conn = get_conn()
    print(f"  [octavia] Creating pool '{name}' ({algorithm})...")
    pool = conn.load_balancer.create_pool(
        name=name,
        listener_id=listener_id,
        protocol=protocol,
        lb_algorithm=algorithm,
    )
    return json.dumps({
        "pool_id": pool.id,
        "name": pool.name,
        "algorithm": pool.lb_algorithm,
        "note": "Call wait_for_load_balancer before proceeding.",
    })

def create_health_monitor(
    pool_id: str,
    type: str,
    delay: int = 10,
    timeout: int = 5,
    max_retries: int = 3,
    url_path: str = "/",
) -> str:
    conn = get_conn()
    print(f"  [octavia] Creating {type} health monitor on pool {pool_id}...")
    kwargs = dict(
        pool_id=pool_id,
        type=type,
        delay=delay,
        timeout=timeout,
        max_retries=max_retries,
    )
    if type in ("HTTP", "HTTPS"):
        kwargs["url_path"] = url_path
    hm = conn.load_balancer.create_health_monitor(**kwargs)
    return json.dumps({
        "health_monitor_id": hm.id,
        "type": hm.type,
        "delay": hm.delay,
        "timeout": hm.timeout,
        "max_retries": hm.max_retries,
        "url_path": getattr(hm, "url_path", None),
        "note": "Call wait_for_load_balancer before proceeding.",
    })

def create_lb_member(
    pool_id: str,
    name: str,
    address: str,
    port: int,
    subnet_name: str,
    weight: int = 1,
) -> str:
    conn = get_conn()
    
    # Use centralized fuzzy finder
    try:
        subnet, matched_name = find_subnet(conn, subnet_name)
    except ValueError as e:
        return json.dumps({"error": str(e)})
    
    print(f"  [octavia] Adding member '{name}' ({address}:{port}) to pool {pool_id}...")
    member = conn.load_balancer.create_member(
        pool_id,
        name=name,
        address=address,
        protocol_port=port,
        subnet_id=subnet.id,
        weight=weight,
    )
    return json.dumps({
        "member_id": member.id,
        "name": member.name,
        "address": member.address,
        "port": member.protocol_port,
        "weight": member.weight,
        "operating_status": member.operating_status,
        "subnet_used": matched_name,
        "note": "Call wait_for_load_balancer before adding the next member.",
    })

def list_lb_listeners(lb_id: str) -> str:
    conn = get_conn()
    listeners = [
        {
            "id": l.id,
            "name": l.name,
            "protocol": l.protocol,
            "port": l.protocol_port,
            "default_pool_id": l.default_pool_id,
        }
        for l in conn.load_balancer.listeners(load_balancer_id=lb_id)
    ]
    return json.dumps(listeners, indent=2)

def list_lb_pools(listener_id: str = None, lb_id: str = None) -> str:
    conn = get_conn()
    pools = list(conn.load_balancer.pools())
    
    if listener_id:
        pools = [p for p in pools if p.listener_id == listener_id]
    if lb_id:
        pools = [p for p in pools if p.load_balancer_id == lb_id]
    
    return json.dumps([
        {
            "id": p.id,
            "name": p.name,
            "protocol": p.protocol,
            "algorithm": p.lb_algorithm,
            "listener_id": p.listener_id,
            "load_balancer_id": p.load_balancer_id,
            "members": [m.id for m in (p.members or [])],
        }
        for p in pools
    ], indent=2)

def list_lb_members(pool_id: str) -> str:
    conn = get_conn()
    members = [
        {
            "id": m.id,
            "name": m.name,
            "address": m.address,
            "port": m.protocol_port,
            "weight": m.weight,
            "operating_status": m.operating_status,
            "admin_state_up": m.admin_state_up,
        }
        for m in conn.load_balancer.members(pool_id)
    ]
    return json.dumps(members, indent=2)

def delete_load_balancer(lb_id: str) -> str:
    conn = get_conn()
    lb = conn.load_balancer.find_load_balancer(lb_id, ignore_missing=False)
    print(f"  [octavia] Deleting load balancer '{lb.name}' (cascade)...")
    conn.load_balancer.delete_load_balancer(lb.id, cascade=True)
    return f"Load balancer '{lb.name}' ({lb.id}) cascade-deleted."

def _delete_lb_by_id(lb_id: str) -> None:
    """Internal teardown function for transaction rollback."""
    conn = get_conn()
    conn.load_balancer.delete_load_balancer(lb_id, cascade=True, ignore_missing=True)

# ── Handler Registry ──────────────────────────────────────────────────────────

LOADBALANCER_HANDLERS = {
    "list_load_balancers":  list_load_balancers,
    "get_load_balancer":    get_load_balancer,
    "create_load_balancer": create_load_balancer,
    "wait_for_load_balancer": wait_for_load_balancer,
    "create_lb_listener":   create_lb_listener,
    "create_lb_pool":       create_lb_pool,
    "create_health_monitor": create_health_monitor,
    "create_lb_member":     create_lb_member,
    "list_lb_listeners":    list_lb_listeners,
    "list_lb_pools":        list_lb_pools,
    "list_lb_members":      list_lb_members,
    "delete_load_balancer": delete_load_balancer,
}
