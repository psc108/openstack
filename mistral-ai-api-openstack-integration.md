# Mistral AI API — OpenStack Integration Guide

**Scope:** Integrating the Mistral AI cloud API with a self-hosted OpenStack environment  
**Approach:** Mistral AI as the LLM brain; OpenStack as the execution target via Python SDK and function calling  
**Auth model:** Mistral API key (La Plateforme) + OpenStack Keystone application credentials  

---

## Architecture Overview

```
Developer / Operator
        │
        ▼
  mistral-os CLI
        │
        ├──► Mistral AI API (api.mistral.ai)
        │         └── mistral-small / mistral-large / codestral
        │               └── function calling → tool dispatch
        │
        └──► OpenStack APIs
                  ├── Nova     (compute / instances)
                  ├── Neutron  (networks / security groups / floating IPs)
                  ├── Glance   (images)
                  ├── Keystone (auth)
                  └── Octavia  (load balancers)
```

The integration operates in two modes:

- **Direct API mode** — Mistral receives OpenStack context (logs, resource lists) and reasons about it in natural language
- **Agentic / function-calling mode** — Mistral plans and executes multi-step OpenStack builds by calling tools you define, chaining calls in dependency order and waiting on async resource state

A single operator request such as:

```
"Create 3 web instances behind an HTTP load balancer called web-lb"
```

causes Mistral to autonomously: discover available images and flavours → create instances → wait for ACTIVE → create load balancer → wait for ACTIVE → create listener → create pool → create health monitor → register each instance as a pool member → optionally assign a floating IP.

---

## Phase 1 — Environment Setup

### 1.1 Accounts and Keys

You need:
- A Mistral La Plateforme account: [console.mistral.ai](https://console.mistral.ai)
- An API key from the La Plateforme console
- OpenStack application credentials (scoped, revocable — preferred over user passwords for automation)

Create OpenStack application credentials:

```bash
openstack application credential create mistral-integration \
  --role member \
  --description "Mistral AI integration service account"
# Note the printed id and secret — you will not see the secret again
```

### 1.2 Python Environment

```bash
python3 -m venv /opt/mistral-openstack
source /opt/mistral-openstack/bin/activate

pip install mistralai openstacksdk python-openstackclient tenacity
```

### 1.3 Environment Variables

```bash
# ~/.config/mistral-openstack/env
# Source this before running anything: source ~/.config/mistral-openstack/env

export MISTRAL_API_KEY="your-la-plateforme-api-key"

# OpenStack — application credential auth
export OS_AUTH_TYPE=v3applicationcredential
export OS_AUTH_URL=https://keystone.your-cloud.internal:5000/v3
export OS_APPLICATION_CREDENTIAL_ID="<id from 1.1>"
export OS_APPLICATION_CREDENTIAL_SECRET="<secret from 1.1>"
export OS_REGION_NAME=RegionOne
```

Verify both sides:

```bash
source ~/.config/mistral-openstack/env
openstack token issue
python -c "from mistralai import Mistral; print('Mistral SDK OK')"
```

### 1.4 Model Selection Reference

| Use case | Model |
|---|---|
| Chat, explain, summarise | `mistral-small-latest` |
| Complex multi-step planning | `mistral-large-latest` |
| Code / config generation | `codestral-latest` |
| Cost-sensitive automation loops | `mistral-small-latest` |

---

## Phase 2 — Project Layout

All source lives under a single directory. Keeping it flat makes the CLI and imports simple.

```
mistral-openstack/
├── client.py           # Mistral client factory
├── os_client.py        # OpenStack connection factory
├── tools/
│   ├── __init__.py     # TOOLS list (all schemas combined)
│   ├── compute.py      # Nova tool schemas + handlers
│   ├── network.py      # Neutron tool schemas + handlers
│   └── loadbalancer.py # Octavia tool schemas + handlers
├── agent.py            # Agentic loop
├── stream.py           # Streaming helper
├── mistral-os          # CLI entrypoint
└── requirements.txt
```

`requirements.txt`:

```
mistralai>=1.0.0
openstacksdk>=3.0.0
python-openstackclient>=6.0.0
tenacity>=8.0.0
```

---

## Phase 3 — Core Clients

### client.py

```python
import os
from mistralai import Mistral
from tenacity import retry, stop_after_attempt, wait_exponential

def get_mistral_client() -> Mistral:
    api_key = os.environ.get("MISTRAL_API_KEY")
    if not api_key:
        raise RuntimeError("MISTRAL_API_KEY is not set")
    return Mistral(api_key=api_key)
```

### os_client.py

```python
import openstack

def get_conn() -> openstack.connection.Connection:
    """
    Returns an OpenStack connection using environment-variable auth.
    Caches the connection per process — safe for single-threaded CLI use.
    """
    return openstack.connect()
```

---

## Phase 4 — Compute Tools (Nova)

### tools/compute.py

Tool schemas tell Mistral what functions exist and what parameters they accept. Handlers execute the actual OpenStack calls.

```python
# tools/compute.py
import json
import time
from os_client import get_conn

# ── Schemas ──────────────────────────────────────────────────────────────────

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

# ── Handlers ──────────────────────────────────────────────────────────────────

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

    image   = conn.compute.find_image(image_name, ignore_missing=False)
    flavour = conn.compute.find_flavor(flavour_name, ignore_missing=False)
    network = conn.network.find_network(network_name, ignore_missing=False)

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

    print(f"  [nova] Creating instance '{name}'...")
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
    return json.dumps({"name": server.name, "id": server.id, "status": server.status, "fixed_ip": ip})


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


COMPUTE_HANDLERS = {
    "list_images":   list_images,
    "list_flavours": list_flavours,
    "list_servers":  list_servers,
    "get_server":    get_server,
    "create_server": create_server,
    "reboot_server": reboot_server,
    "delete_server": delete_server,
}
```

---

## Phase 5 — Network Tools (Neutron)

```python
# tools/network.py
import json
from os_client import get_conn

# ── Schemas ──────────────────────────────────────────────────────────────────

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
]

# ── Handlers ──────────────────────────────────────────────────────────────────

def list_networks() -> str:
    conn = get_conn()
    nets = [
        {
            "name": n.name,
            "id": n.id,
            "status": n.status,
            "external": n.is_router_external,
            "shared": n.is_shared,
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
        {"name": s.name, "id": s.id, "cidr": s.cidr, "network_id": s.network_id}
        for s in subnets
    ], indent=2)


def list_security_groups() -> str:
    conn = get_conn()
    sgs = [
        {"name": sg.name, "id": sg.id, "description": sg.description}
        for sg in conn.network.security_groups()
    ]
    return json.dumps(sorted(sgs, key=lambda x: x["name"]), indent=2)


def assign_floating_ip(external_network_name: str, port_id: str) -> str:
    conn = get_conn()
    ext_net = conn.network.find_network(external_network_name, ignore_missing=False)
    fip = conn.network.create_ip(
        floating_network_id=ext_net.id,
        port_id=port_id,
    )
    print(f"  [neutron] Floating IP {fip.floating_ip_address} → port {port_id}")
    return json.dumps({
        "floating_ip": fip.floating_ip_address,
        "floating_ip_id": fip.id,
        "port_id": port_id,
    })


NETWORK_HANDLERS = {
    "list_networks":        list_networks,
    "list_subnets":         list_subnets,
    "list_security_groups": list_security_groups,
    "assign_floating_ip":   assign_floating_ip,
}
```

---

## Phase 6 — Load Balancer Tools (Octavia)

This is the most complex section because Octavia resources are provisioned asynchronously. Every create operation must be followed by a wait — Mistral is told this explicitly in each tool description so it calls `wait_for_load_balancer` at the right points.

The full build sequence for "3 instances + HTTP load balancer" is:

```
create_load_balancer  →  wait_for_load_balancer (ACTIVE)
create_lb_listener    →  wait_for_load_balancer (ACTIVE)
create_lb_pool        →  wait_for_load_balancer (ACTIVE)
create_health_monitor →  wait_for_load_balancer (ACTIVE)
create_lb_member (×3) →  wait_for_load_balancer (ACTIVE) each
[optional: assign_floating_ip to VIP port]
```

```python
# tools/loadbalancer.py
import json
import time
from os_client import get_conn

# ── Schemas ──────────────────────────────────────────────────────────────────

LOADBALANCER_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_load_balancers",
            "description": "List existing Octavia load balancers.",
            "parameters": {"type": "object", "properties": {}, "required": []},
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
                },
                "required": ["pool_id", "name", "address", "port", "subnet_name"],
            },
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

# ── Helpers ───────────────────────────────────────────────────────────────────

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

# ── Handlers ──────────────────────────────────────────────────────────────────

def list_load_balancers() -> str:
    conn = get_conn()
    lbs = [
        {
            "name": lb.name,
            "id": lb.id,
            "provisioning_status": lb.provisioning_status,
            "operating_status": lb.operating_status,
            "vip_address": lb.vip_address,
        }
        for lb in conn.load_balancer.load_balancers()
    ]
    return json.dumps(lbs, indent=2) if lbs else "No load balancers found."


def create_load_balancer(name: str, subnet_name: str, description: str = "") -> str:
    conn = get_conn()
    subnet = conn.network.find_subnet(subnet_name, ignore_missing=False)
    print(f"  [octavia] Creating load balancer '{name}' on subnet '{subnet_name}'...")
    lb = conn.load_balancer.create_load_balancer(
        name=name,
        vip_subnet_id=subnet.id,
        description=description,
    )
    return json.dumps({
        "lb_id": lb.id,
        "name": lb.name,
        "vip_address": lb.vip_address,
        "vip_port_id": lb.vip_port_id,
        "provisioning_status": lb.provisioning_status,
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
        "note": "Call wait_for_load_balancer before proceeding.",
    })


def create_lb_member(
    pool_id: str,
    name: str,
    address: str,
    port: int,
    subnet_name: str,
) -> str:
    conn = get_conn()
    subnet = conn.network.find_subnet(subnet_name, ignore_missing=False)
    print(f"  [octavia] Adding member '{name}' ({address}:{port}) to pool {pool_id}...")
    member = conn.load_balancer.create_member(
        pool_id,
        name=name,
        address=address,
        protocol_port=port,
        subnet_id=subnet.id,
    )
    return json.dumps({
        "member_id": member.id,
        "name": member.name,
        "address": member.address,
        "port": member.protocol_port,
        "operating_status": member.operating_status,
        "note": "Call wait_for_load_balancer before adding the next member.",
    })


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
    })


def delete_load_balancer(lb_id: str) -> str:
    conn = get_conn()
    lb = conn.load_balancer.find_load_balancer(lb_id, ignore_missing=False)
    conn.load_balancer.delete_load_balancer(lb.id, cascade=True)
    return f"Load balancer '{lb.name}' ({lb.id}) cascade-deleted."


LOADBALANCER_HANDLERS = {
    "list_load_balancers":  list_load_balancers,
    "create_load_balancer": create_load_balancer,
    "wait_for_load_balancer": wait_for_load_balancer,
    "create_lb_listener":   create_lb_listener,
    "create_lb_pool":       create_lb_pool,
    "create_health_monitor": create_health_monitor,
    "create_lb_member":     create_lb_member,
    "get_load_balancer":    get_load_balancer,
    "delete_load_balancer": delete_load_balancer,
}
```

---

## Phase 7 — Tool Registry

A single file that combines all schemas and handlers so the agent only needs one import.

```python
# tools/__init__.py
from tools.compute      import COMPUTE_TOOLS,      COMPUTE_HANDLERS
from tools.network      import NETWORK_TOOLS,       NETWORK_HANDLERS
from tools.loadbalancer import LOADBALANCER_TOOLS,  LOADBALANCER_HANDLERS

TOOLS = COMPUTE_TOOLS + NETWORK_TOOLS + LOADBALANCER_TOOLS

HANDLERS = {
    **COMPUTE_HANDLERS,
    **NETWORK_HANDLERS,
    **LOADBALANCER_HANDLERS,
}

# Tools that require operator confirmation before execution
DESTRUCTIVE_TOOLS = {
    "delete_server",
    "delete_load_balancer",
    "reboot_server",
}
```

---

## Phase 8 — Agent Loop

The agent loop drives a conversation with Mistral until it reaches a final natural-language answer with no pending tool calls. Mistral chains tool calls in the correct dependency order itself — the loop just executes whatever it requests.

```python
# agent.py
import json
import sys
from mistralai import Mistral
from client import get_mistral_client
from tools import TOOLS, HANDLERS, DESTRUCTIVE_TOOLS

SYSTEM_PROMPT = """You are an OpenStack infrastructure assistant with tools to inspect,
build, and manage resources on a self-hosted OpenStack cloud.

When asked to provision resources (instances, load balancers, etc.) you:
1. First call list_images, list_flavours, list_networks, and list_subnets to discover
   what is available before making any assumptions about names or IDs.
2. Create resources in dependency order: instances first, then load balancer, listener,
   pool, health monitor, then members.
3. After EVERY Octavia operation (create_load_balancer, create_lb_listener, create_lb_pool,
   create_health_monitor, create_lb_member), call wait_for_load_balancer before proceeding.
   Octavia is asynchronous and will reject requests if the LB is not ACTIVE.
4. When creating multiple instances of the same type, create them one at a time with
   individual create_server calls. Do not attempt bulk creation.
5. Report a clear summary of everything created at the end, including IDs and IP addresses.

For destructive operations (delete, reboot), always describe what you are about to do
before calling the tool so the operator has context in the output."""


def confirm_destructive(fn_name: str, fn_args: dict) -> bool:
    print(f"\n  ⚠  Destructive operation: {fn_name}({json.dumps(fn_args)})")
    answer = input("  Proceed? [y/N] ").strip().lower()
    return answer == "y"


def run_agent(
    user_request: str,
    model: str = "mistral-small-latest",
    require_confirm: bool = True,
) -> None:
    client = get_mistral_client()
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user",   "content": user_request},
    ]

    print(f"\n[agent] Model: {model}")
    print(f"[agent] Request: {user_request}\n")

    iteration = 0
    while True:
        iteration += 1
        response = client.chat.complete(
            model=model,
            messages=messages,
            tools=TOOLS,
            tool_choice="auto",
        )

        msg = response.choices[0].message
        messages.append(msg)

        # No tool calls — Mistral has produced its final answer
        if not msg.tool_calls:
            print("\n" + "─" * 60)
            print(msg.content)
            break

        # Execute each tool call in this response
        for call in msg.tool_calls:
            fn_name = call.function.name
            fn_args = json.loads(call.function.arguments)

            # Gate destructive operations behind confirmation
            if require_confirm and fn_name in DESTRUCTIVE_TOOLS:
                if not confirm_destructive(fn_name, fn_args):
                    result = f"Operation '{fn_name}' cancelled by operator."
                    messages.append({
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": result,
                    })
                    continue

            handler = HANDLERS.get(fn_name)
            if not handler:
                result = f"ERROR: Unknown tool '{fn_name}'."
            else:
                try:
                    result = handler(**fn_args)
                except Exception as exc:
                    result = f"ERROR in {fn_name}: {exc}"
                    print(f"  [error] {fn_name}: {exc}", file=sys.stderr)

            messages.append({
                "role": "tool",
                "tool_call_id": call.id,
                "content": result,
            })
```

---

## Phase 9 — CLI Wrapper

```python
#!/usr/bin/env python3
# mistral-os
"""
Mistral AI + OpenStack natural-language CLI.

Usage:
  mistral-os "List all running instances"
  mistral-os "Create 3 web instances behind an HTTP load balancer called web-lb"
  mistral-os --model mistral-large-latest "Create a 3-tier stack: 2 web, 2 app, 1 db"
  mistral-os --no-confirm "Reboot the server named test-01"
  journalctl -u nova-compute -n 100 | mistral-os --explain
"""
import argparse
import sys
from agent import run_agent


def main():
    parser = argparse.ArgumentParser(
        description="Mistral AI OpenStack assistant",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "query", nargs="*",
        help="Natural language instruction or query.",
    )
    parser.add_argument(
        "--model", default="mistral-small-latest",
        help="Mistral model. Default: mistral-small-latest. Use mistral-large-latest for complex builds.",
    )
    parser.add_argument(
        "--explain", action="store_true",
        help="Read stdin and ask Mistral to diagnose it (log analysis mode).",
    )
    parser.add_argument(
        "--no-confirm", action="store_true",
        help="Skip confirmation prompts for destructive operations (use with care).",
    )
    args = parser.parse_args()

    if args.explain:
        stdin_text = sys.stdin.read().strip()
        if not stdin_text:
            print("No input on stdin.", file=sys.stderr)
            sys.exit(1)
        query = (
            "You are an OpenStack expert. Analyse the following log or command output. "
            "Identify errors or warnings, explain the root cause, and suggest remediation steps.\n\n"
            + stdin_text
        )
        run_agent(query, model=args.model, require_confirm=False)

    elif args.query:
        run_agent(
            " ".join(args.query),
            model=args.model,
            require_confirm=not args.no_confirm,
        )
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
```

Install:

```bash
chmod +x mistral-os
sudo cp mistral-os /usr/local/bin/mistral-os
```

---

## Phase 10 — End-to-End Example: 3 Instances + Load Balancer

This is the canonical scenario. A single command:

```bash
mistral-os --model mistral-large-latest \
  "Create 3 instances named web-01, web-02, web-03 using the ubuntu-22.04 image \
   on the m1.medium flavour, on the internal network. \
   Then put them behind an HTTP load balancer called web-lb on port 80 \
   with a health check on /healthcheck. \
   Finally assign a floating IP from the external network to the load balancer."
```

What Mistral does (you will see this in the terminal as it runs):

```
[agent] Model: mistral-large-latest
[agent] Request: Create 3 instances named web-01 ...

  [tool] list_images({})
  [tool] list_flavours({})
  [tool] list_networks({})
  [tool] list_subnets({"network_name": "internal"})

  [nova]  Creating instance 'web-01'...
  [nova]  Instance 'web-01' ACTIVE — IP: 192.168.1.101
  [nova]  Creating instance 'web-02'...
  [nova]  Instance 'web-02' ACTIVE — IP: 192.168.1.102
  [nova]  Creating instance 'web-03'...
  [nova]  Instance 'web-03' ACTIVE — IP: 192.168.1.103

  [octavia] Creating load balancer 'web-lb' on subnet 'internal-subnet'...
  [octavia] Waiting for load balancer <id> to become ACTIVE...
  [octavia] Load balancer <id> is ACTIVE.

  [octavia] Creating listener 'web-lb-listener' (HTTP:80)...
  [octavia] Waiting for load balancer <id> to become ACTIVE...
  [octavia] Load balancer <id> is ACTIVE.

  [octavia] Creating pool 'web-lb-pool' (ROUND_ROBIN)...
  [octavia] Waiting for load balancer <id> to become ACTIVE...
  [octavia] Load balancer <id> is ACTIVE.

  [octavia] Creating HTTP health monitor on pool <id>...
  [octavia] Waiting for load balancer <id> to become ACTIVE...
  [octavia] Load balancer <id> is ACTIVE.

  [octavia] Adding member 'web-01' (192.168.1.101:80) to pool <id>...
  [octavia] Waiting for load balancer <id> to become ACTIVE...
  [octavia] Adding member 'web-02' (192.168.1.102:80) to pool <id>...
  [octavia] Waiting for load balancer <id> to become ACTIVE...
  [octavia] Adding member 'web-03' (192.168.1.103:80) to pool <id>...
  [octavia] Waiting for load balancer <id> to become ACTIVE...

  [neutron] Floating IP 203.0.113.42 → port <vip-port-id>

────────────────────────────────────────────────────
Build complete. Here is a summary of what was created:

Instances:
  web-01   192.168.1.101   ACTIVE
  web-02   192.168.1.102   ACTIVE
  web-03   192.168.1.103   ACTIVE

Load Balancer: web-lb
  VIP (internal):  10.0.0.50
  Floating IP:     203.0.113.42
  Listener:        HTTP port 80
  Pool algorithm:  ROUND_ROBIN
  Health monitor:  HTTP GET /healthcheck (delay=10s, timeout=5s, retries=3)
  Members:         web-01, web-02, web-03

HTTP traffic to http://203.0.113.42/ will be round-robin distributed
across the three backend instances.
```

---

## Phase 11 — Further Example Requests

Once the toolset is in place, Mistral handles a wide range of natural language requests without code changes.

```bash
# Status and inspection
mistral-os "What instances are currently in ERROR state?"
mistral-os "Show me all load balancers and their operating status"
mistral-os "List everything on the internal network — instances, their IPs, and any load balancers"

# Simple builds
mistral-os "Create a single Ubuntu instance called bastion on the m1.small flavour"
mistral-os "Create 2 instances called db-01 and db-02 using the centos-9 image on m1.large"

# Load balanced stacks
mistral-os "Build a 2-node web tier behind an HTTP LB called frontend-lb"
mistral-os "Create 4 app servers called app-01 through app-04 and put them behind \
            a TCP load balancer on port 8080 called app-lb"

# Teardown
mistral-os "Delete the load balancer web-lb"
mistral-os "Delete instances web-01, web-02, and web-03"

# Log analysis
journalctl -u neutron-server -n 200 | mistral-os --explain
openstack server list -f json | mistral-os --explain
```

---

## Phase 12 — Hardening

### 12.1 Secrets Management

Never hard-code credentials. For a systemd service context:

```ini
# /etc/systemd/system/mistral-os.service
[Unit]
Description=Mistral OS agent (non-interactive)

[Service]
EnvironmentFile=/etc/mistral-openstack/secrets
ExecStart=/usr/local/bin/mistral-os %I
User=mistral
```

`/etc/mistral-openstack/secrets` (mode 0600, owned by `mistral`):

```
MISTRAL_API_KEY=...
OS_AUTH_TYPE=v3applicationcredential
OS_AUTH_URL=https://keystone.internal:5000/v3
OS_APPLICATION_CREDENTIAL_ID=...
OS_APPLICATION_CREDENTIAL_SECRET=...
OS_REGION_NAME=RegionOne
```

### 12.2 Audit Logging

```python
# Add to agent.py, in the tool dispatch block
import logging
import datetime

logging.basicConfig(
    filename="/var/log/mistral-os/audit.log",
    level=logging.INFO,
    format="%(asctime)s %(message)s",
)

# Before executing handler:
logging.info(f"CALL fn={fn_name} args={json.dumps(fn_args)}")
# After:
logging.info(f"RESULT fn={fn_name} result={str(result)[:300]}")
```

### 12.3 API Retries

The Mistral API can return transient 429/503 responses. Wrap the completion call:

```python
from tenacity import retry, stop_after_attempt, wait_exponential

@retry(
    wait=wait_exponential(multiplier=1, min=2, max=30),
    stop=stop_after_attempt(4),
)
def _complete(client, **kwargs):
    return client.chat.complete(**kwargs)
```

### 12.4 Model Routing by Complexity

```python
def pick_model(request: str) -> str:
    """Simple heuristic — escalate to large for complex builds."""
    escalation_keywords = [
        "create", "build", "provision", "deploy", "stack",
        "load balancer", "multiple", "tier", "cluster",
    ]
    request_lower = request.lower()
    if any(kw in request_lower for kw in escalation_keywords):
        return "mistral-large-latest"
    return "mistral-small-latest"
```

Use in the CLI by passing `--model auto` and resolving before calling `run_agent`.

### 12.5 Context Window Hygiene

Long builds accumulate many tool result messages. For very large stacks (10+ resources), trim completed tool results from the history to stay within the model's context window:

```python
def trim_tool_results(messages: list, keep_last: int = 10) -> list:
    """
    Keep the system prompt, all user/assistant messages, and only the
    most recent N tool result messages to avoid context overflow.
    """
    system = [m for m in messages if isinstance(m, dict) and m.get("role") == "system"]
    non_tool = [m for m in messages if not (isinstance(m, dict) and m.get("role") == "tool")]
    tool_results = [m for m in messages if isinstance(m, dict) and m.get("role") == "tool"]
    return system + non_tool + tool_results[-keep_last:]
```

---

## Appendix A — Streaming Mode

For analysis tasks where you want progressive output rather than waiting for the full response:

```python
# stream.py
from client import get_mistral_client

def stream_query(prompt: str, model: str = "mistral-small-latest") -> None:
    client = get_mistral_client()
    with client.chat.stream(
        model=model,
        messages=[
            {"role": "system", "content": "You are an OpenStack infrastructure expert."},
            {"role": "user",   "content": prompt},
        ],
    ) as stream:
        for chunk in stream:
            delta = chunk.choices[0].delta.content
            if delta:
                print(delta, end="", flush=True)
    print()
```

Usage via CLI:

```bash
# Pipe log output into streaming explain mode
journalctl -u nova-compute --since "1 hour ago" | \
  python -c "
import sys
from stream import stream_query
stream_query(sys.stdin.read())
"
```

---

## Appendix B — Adding New Tools

The architecture is designed to make tool addition straightforward. To add, for example, Swift object storage tools:

1. Create `tools/objectstore.py` with `OBJECTSTORE_TOOLS` (schemas) and `OBJECTSTORE_HANDLERS` (handlers), following the same pattern as `compute.py`.
2. Import and register in `tools/__init__.py`:

```python
from tools.objectstore import OBJECTSTORE_TOOLS, OBJECTSTORE_HANDLERS
TOOLS    = COMPUTE_TOOLS + NETWORK_TOOLS + LOADBALANCER_TOOLS + OBJECTSTORE_TOOLS
HANDLERS = {**COMPUTE_HANDLERS, **NETWORK_HANDLERS, **LOADBALANCER_HANDLERS, **OBJECTSTORE_HANDLERS}
```

3. No changes needed to `agent.py`, `mistral-os`, or the system prompt (unless you want to add usage guidance for the new tools).

Candidate tool modules for future phases:

| Module | Covers |
|---|---|
| `tools/objectstore.py` | Swift containers and objects |
| `tools/volume.py` | Cinder volumes and snapshots |
| `tools/dns.py` | Designate DNS zones and records |
| `tools/keypair.py` | Nova key pair management |
| `tools/quota.py` | Project quota inspection and reporting |
| `tools/image.py` | Glance image upload and management |

---

*Mistral API reference: [docs.mistral.ai](https://docs.mistral.ai) — OpenStack SDK reference: [docs.openstack.org/openstacksdk](https://docs.openstack.org/openstacksdk/latest/)*

---

## Phase 13 — Rollback on Failure

### Problem

A multi-step build — three instances, a load balancer, a listener, a pool, a health monitor, three members — can fail at any point. Without a rollback mechanism, a mid-build failure leaves orphaned resources: instances consuming quota, an incomplete load balancer, partial pool membership. The next run may fail because resources with the same names already exist.

### Design

A `BuildTransaction` context manager wraps the agent loop. It maintains a registry of every resource created, ordered by creation sequence. On any unhandled exception it works backwards through the registry, deleting in reverse order (members → health monitor → pool → listener → load balancer → instances → floating IPs). Each teardown step is itself guarded so a failure during rollback does not abort the remaining cleanup.

```python
# rollback.py
import json
import logging
import sys
from dataclasses import dataclass, field
from typing import Callable, List
from os_client import get_conn

log = logging.getLogger("mistral-os.rollback")


@dataclass
class CreatedResource:
    """A single resource created during a build, with its teardown callable."""
    resource_type: str   # human label e.g. "instance", "load_balancer"
    resource_id:   str   # UUID
    resource_name: str   # display name
    teardown:      Callable[[], None]  # zero-arg callable that deletes this resource


class BuildTransaction:
    """
    Context manager that records created resources and rolls them back
    in reverse order if the build raises an exception.

    Usage:
        with BuildTransaction() as tx:
            server_id = create_server(...)
            tx.register("instance", server_id, "web-01", lambda: delete_server(server_id))

            lb_id = create_load_balancer(...)
            tx.register("load_balancer", lb_id, "web-lb", lambda: delete_lb(lb_id))
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
                # Log and continue — do not let one failed teardown abort the rest
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
```

### Integrating the Transaction into Handlers

The handlers in `tools/compute.py` and `tools/loadbalancer.py` need to register each created resource with the active transaction. Pass the transaction as an optional parameter through a module-level reference, or inject it at agent startup.

The cleanest approach for a CLI tool is a module-level singleton:

```python
# transaction.py
from rollback import BuildTransaction

# Active transaction — set by the agent before a build, cleared after
_active_tx: BuildTransaction = None

def set_transaction(tx: BuildTransaction) -> None:
    global _active_tx
    _active_tx = tx

def get_transaction() -> BuildTransaction:
    return _active_tx
```

Then in each handler, register after a successful create:

```python
# In tools/compute.py create_server(), after wait_for_server():
from transaction import get_transaction

tx = get_transaction()
if tx:
    tx.register(
        resource_type="instance",
        resource_id=server.id,
        resource_name=server.name,
        teardown=lambda sid=server.id: _delete_server_by_id(sid),
    )
```

```python
# In tools/loadbalancer.py create_load_balancer(), after creation:
from transaction import get_transaction

tx = get_transaction()
if tx:
    tx.register(
        resource_type="load_balancer",
        resource_id=lb.id,
        resource_name=name,
        teardown=lambda lid=lb.id: _delete_lb_by_id(lid),
    )
```

Add bare teardown functions (not wrapped in tool handlers) for internal use:

```python
# In tools/compute.py
def _delete_server_by_id(server_id: str) -> None:
    conn = get_conn()
    conn.compute.delete_server(server_id, ignore_missing=True)

# In tools/loadbalancer.py
def _delete_lb_by_id(lb_id: str) -> None:
    conn = get_conn()
    conn.load_balancer.delete_load_balancer(lb_id, cascade=True, ignore_missing=True)

def _delete_member_by_id(pool_id: str, member_id: str) -> None:
    conn = get_conn()
    conn.load_balancer.delete_member(member_id, pool_id, ignore_missing=True)

def _delete_fip_by_id(fip_id: str) -> None:
    conn = get_conn()
    conn.network.delete_ip(fip_id, ignore_missing=True)
```

### Wiring into the Agent Loop

```python
# agent.py — updated run_agent() signature and body

from rollback import BuildTransaction
from transaction import set_transaction

def run_agent(
    user_request: str,
    model: str = "mistral-small-latest",
    require_confirm: bool = True,
    enable_rollback: bool = True,
) -> None:

    tx = BuildTransaction() if enable_rollback else None
    set_transaction(tx)

    try:
        _run_agent_inner(user_request, model, require_confirm)
        if tx:
            tx.commit()
            print(f"\n[tx] Build committed. Resources created:\n{tx.summary()}")
    except KeyboardInterrupt:
        print("\n[tx] Interrupted by operator.", file=sys.stderr)
        # rollback fires via __exit__ if used as context manager,
        # or call explicitly here
        if tx:
            tx.rollback()
        raise
    except Exception as exc:
        print(f"\n[tx] Build failed: {exc}", file=sys.stderr)
        if tx:
            tx.rollback()
        raise
    finally:
        set_transaction(None)
```

### Rollback Order for a Full LB Stack

The registry, when populated by a complete 3-instance + LB build, will contain entries in this order:

```
0  instance       web-01       <id>
1  instance       web-02       <id>
2  instance       web-03       <id>
3  load_balancer  web-lb       <id>   ← cascade=True covers listener/pool/hm/members
4  floating_ip    203.0.113.42 <id>
```

Rollback iterates in reverse: `floating_ip → load_balancer (cascade) → web-03 → web-02 → web-01`.

The cascade delete on the load balancer removes listener, pool, health monitor, and members in one call, so individual registration of those child resources is not required unless you want finer-grained rollback reporting.

### CLI Flag

```bash
# Rollback enabled by default — disable if you want to inspect partial builds
mistral-os --no-rollback "Create 3 web instances behind web-lb"
```

Add `--no-rollback` to the `argparse` block in `mistral-os`:

```python
parser.add_argument(
    "--no-rollback", action="store_true",
    help="Do not roll back resources if the build fails. Useful for debugging partial builds.",
)
```

---

## Phase 14 — Concurrent Instance Creation

### Problem

When creating three or more instances, the current implementation is fully serial: it waits for `web-01` to reach ACTIVE before starting `web-02`. Each instance typically takes 30–90 seconds. For a 3-instance build this means 90–270 seconds of sequential waiting when the instances are completely independent and could be created simultaneously.

### Design

Nova instance creation is parallelisable because instances have no dependency on each other. Octavia operations are **not** parallelisable — the load balancer must be ACTIVE between each step. The concurrency strategy is therefore:

```
Phase A (parallel):   create web-01, web-02, web-03 simultaneously
                      ↓ all three reach ACTIVE
Phase B (serial):     create LB → listener → pool → health monitor → members
```

`concurrent.futures.ThreadPoolExecutor` is the right tool here. The openstacksdk connection object is not thread-safe to share, so each worker calls `get_conn()` independently to obtain its own connection.

```python
# tools/compute.py — add alongside existing handlers

import concurrent.futures
from typing import List, Dict, Any

def create_servers_parallel(
    server_specs: List[Dict[str, Any]],
    max_workers: int = 5,
) -> str:
    """
    Create multiple Nova instances concurrently and wait for all to reach ACTIVE.

    server_specs is a list of dicts, each matching the create_server() parameters:
        [
            {"name": "web-01", "image_name": "ubuntu-22.04",
             "flavour_name": "m1.medium", "network_name": "internal"},
            {"name": "web-02", ...},
            ...
        ]

    Returns a JSON list of created server details (name, id, status, fixed_ip).
    Any individual failure is collected and reported; partial successes are returned.
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

                # Register with active transaction if present
                from transaction import get_transaction
                tx = get_transaction()
                if tx:
                    sid = result["id"]
                    tx.register(
                        resource_type="instance",
                        resource_id=sid,
                        resource_name=result["name"],
                        teardown=lambda s=sid: _delete_server_by_id(s),
                    )

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
```

### Tool Schema for Parallel Creation

Add this alongside `create_server` in `COMPUTE_TOOLS`:

```python
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
```

Register the handler:

```python
# In COMPUTE_HANDLERS dict:
"create_servers_parallel": create_servers_parallel,
```

### Updated System Prompt Guidance

Add to `SYSTEM_PROMPT` in `agent.py`:

```python
"""
When creating 2 or more instances that share the same image, flavour, and network,
prefer create_servers_parallel over multiple create_server calls. This is faster
and reduces the time before load balancer operations can begin.
Only use individual create_server calls when instances differ in image, flavour,
network, or user_data, or when creating a single instance.
"""
```

### Timing Comparison

For a 3-instance build where each instance takes ~60 seconds to reach ACTIVE:

| Approach | Time to all ACTIVE |
|---|---|
| Serial `create_server` × 3 | ~180 seconds |
| `create_servers_parallel` | ~65 seconds |

For larger builds (10 instances), the difference is proportionally larger: ~600s serial vs ~70s parallel (assuming sufficient Nova scheduler headroom).

### Thread Safety Notes

- Each worker calls `get_conn()` independently — `openstack.connect()` creates a new connection per call so there is no shared state.
- The `BuildTransaction` registry is written from multiple threads. Wrap the `tx.register()` call in a lock if running at high concurrency:

```python
# In transaction.py
import threading
_tx_lock = threading.Lock()

def register_resource(resource_type, resource_id, resource_name, teardown):
    tx = get_transaction()
    if tx:
        with _tx_lock:
            tx.register(resource_type, resource_id, resource_name, teardown)
```

---

## Phase 15 — Quota and Cost Awareness

### Problem

A large build request — "create 20 web servers and 4 load balancers" — may fail halfway through because the project has insufficient Nova vCPU quota, Neutron floating IP quota, or Octavia load balancer quota. Discovering this at step 12 of 30, after spending API calls and potentially incurring cost, is wasteful. The build should fail fast with a clear explanation before any resources are created.

### 15.1 Quota Checker

```python
# quota.py
import json
from os_client import get_conn


def get_compute_headroom() -> dict:
    """
    Returns current Nova quota usage and available headroom for the project.
    Uses conn.compute.get_limits() which maps to GET /limits.
    """
    conn = get_conn()
    limits = conn.compute.get_limits()
    absolute = limits.absolute

    # absolute is a list of dicts: {"name": "maxTotalInstances", "value": 10}
    # and {"name": "totalInstancesUsed", "value": 3}
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
            # Neutron returns {"limit": X, "used": Y, "reserved": Z}
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


def get_lb_headroom() -> dict:
    """
    Returns Octavia quota usage for load balancers and listeners.
    Octavia quotas are project-scoped.
    """
    conn = get_conn()
    try:
        proj  = conn.current_project_id
        quota = conn.load_balancer.get_quota(proj)
        return {
            "load_balancers": {
                "limit": quota.load_balancer,
                "note":  "Use -1 for unlimited",
            },
            "listeners": {
                "limit": quota.listener,
            },
            "pools": {
                "limit": quota.pool,
            },
            "members": {
                "limit": quota.member,
            },
        }
    except Exception:
        return {"note": "Octavia quota API unavailable — proceeding without LB quota check."}


def check_build_feasibility(
    instance_count: int,
    vcpus_per_instance: int,
    ram_mb_per_instance: int,
    floating_ip_count: int = 0,
    load_balancer_count: int = 0,
) -> dict:
    """
    Check whether the requested build fits within current project quota.
    Returns a dict with "feasible": True/False and a list of "issues".
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
```

### 15.2 Cost Estimator

OpenStack does not expose billing natively (unless you have Cloudkitty deployed). The cost estimator uses a local pricing table — operators populate it with their internal chargeback rates or cloud provider costs.

```python
# cost.py
import json
from typing import Dict, List

# ── Pricing table ─────────────────────────────────────────────────────────────
# Populate with your internal chargeback rates or external cloud pricing.
# All costs are per hour in your currency unit (e.g. GBP, USD, EUR).

FLAVOUR_COST_PER_HOUR: Dict[str, float] = {
    "m1.tiny":    0.01,
    "m1.small":   0.03,
    "m1.medium":  0.06,
    "m1.large":   0.12,
    "m1.xlarge":  0.24,
    # GPU flavours
    "gpu.small":  0.80,
    "gpu.medium": 1.60,
}

FLOATING_IP_COST_PER_HOUR: float = 0.004   # per floating IP
LOAD_BALANCER_COST_PER_HOUR: float = 0.02  # per Octavia LB
VOLUME_COST_PER_GB_HOUR: float = 0.0001    # per GB of Cinder volume


def estimate_build_cost(
    instance_specs: List[Dict],           # [{"name": "web-01", "flavour_name": "m1.medium"}, ...]
    floating_ip_count: int = 0,
    load_balancer_count: int = 0,
    volume_gb: int = 0,
    duration_hours: float = 730,          # default: one month
) -> dict:
    """
    Estimate the cost of a proposed build over a given duration.
    Returns itemised and total cost.
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
                "note":     "No pricing data — add to FLAVOUR_COST_PER_HOUR",
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
        "currency_note":  "Costs are estimates. Update FLAVOUR_COST_PER_HOUR in cost.py with actual rates.",
    }
```

### 15.3 Tool Schemas for Quota and Cost

Add these to a new `tools/quota.py` file and register in `tools/__init__.py`:

```python
# tools/quota.py
import json
from quota import check_build_feasibility, get_compute_headroom, get_network_headroom, get_lb_headroom
from cost import estimate_build_cost

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
]


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
    return json.dumps(result, indent=2)


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


QUOTA_HANDLERS = {
    "check_quota_headroom": check_quota_headroom,
    "estimate_cost":        estimate_cost,
}
```

Register in `tools/__init__.py`:

```python
from tools.quota import QUOTA_TOOLS, QUOTA_HANDLERS

TOOLS    = COMPUTE_TOOLS + NETWORK_TOOLS + LOADBALANCER_TOOLS + QUOTA_TOOLS
HANDLERS = {
    **COMPUTE_HANDLERS,
    **NETWORK_HANDLERS,
    **LOADBALANCER_HANDLERS,
    **QUOTA_HANDLERS,
}
```

### 15.4 Updated System Prompt Guidance

Add to `SYSTEM_PROMPT` in `agent.py`:

```python
"""
Before executing any build that creates 2 or more instances or any load balancer:
1. Call list_flavours to confirm the requested flavour and note its vCPU and RAM values.
2. Call check_quota_headroom with the instance count, vCPUs, RAM, and any floating IPs
   or load balancers required. If the result shows feasible=false, report the quota
   issues to the operator and do NOT proceed with the build.
3. Call estimate_cost so the operator can see the projected cost before resources
   are created. Present the cost summary clearly.
Only proceed with the build after both checks pass and the operator has seen the cost estimate.
"""
```

### 15.5 Example Flow with Quota and Cost Checks

```
mistral-os "Create 10 web instances behind a load balancer with a floating IP"

[tool] list_flavours({})
[tool] check_quota_headroom({
         "instance_count": 10,
         "vcpus_per_instance": 2,
         "ram_mb_per_instance": 4096,
         "floating_ip_count": 1,
         "load_balancer_count": 1
       })

→ feasible: false
→ issues: ["VCPUS: need 20, only 12 free (limit 20, used 8)"]

────────────────────────────────────────────────────
I cannot proceed with this build. The project has insufficient vCPU quota:

  Needed:    20 vCPUs (10 × m1.small @ 2 vCPUs)
  Available: 12 vCPUs (limit 20, currently using 8)

Options:
  1. Reduce to 6 instances (12 vCPUs available)
  2. Ask your administrator to raise the vCPU quota for this project
  3. Use a flavour with fewer vCPUs (e.g. m1.tiny at 1 vCPU)

No resources have been created.
```

```
mistral-os "Create 3 web instances behind a load balancer with a floating IP"

[tool] list_flavours({})
[tool] check_quota_headroom({"instance_count": 3, "vcpus_per_instance": 2,
                              "ram_mb_per_instance": 4096,
                              "floating_ip_count": 1, "load_balancer_count": 1})
→ feasible: true

[tool] estimate_cost({
         "instance_specs": [
           {"name": "web-01", "flavour_name": "m1.small"},
           {"name": "web-02", "flavour_name": "m1.small"},
           {"name": "web-03", "flavour_name": "m1.small"}
         ],
         "floating_ip_count": 1,
         "load_balancer_count": 1,
         "duration_hours": 730
       })

────────────────────────────────────────────────────
Quota check passed. Estimated monthly cost:

  3 × m1.small @ £0.03/hr    £65.70
  1 × floating IP @ £0.004/hr £2.92
  1 × load balancer @ £0.02/hr £14.60
  ─────────────────────────────────
  Total (730 hrs / 1 month):  £83.22

Proceed with build? [The agent will then await confirmation or proceed
depending on --no-confirm flag]
```

### 15.6 Pricing Table Maintenance

The `FLAVOUR_COST_PER_HOUR` table in `cost.py` is the only file that needs updating when rates change. For larger deployments, externalise it:

```python
# cost.py — load from file instead of hard-coding
import json, os

_PRICING_FILE = os.environ.get(
    "MISTRAL_OS_PRICING_FILE",
    "/etc/mistral-openstack/pricing.json"
)

def _load_pricing() -> dict:
    try:
        with open(_PRICING_FILE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}   # fall back to empty — tools will report missing pricing

FLAVOUR_COST_PER_HOUR = _load_pricing().get("flavours", {})
FLOATING_IP_COST_PER_HOUR  = _load_pricing().get("floating_ip_per_hour", 0.004)
LOAD_BALANCER_COST_PER_HOUR = _load_pricing().get("load_balancer_per_hour", 0.02)
VOLUME_COST_PER_GB_HOUR    = _load_pricing().get("volume_per_gb_hour", 0.0001)
```

`/etc/mistral-openstack/pricing.json`:

```json
{
  "flavours": {
    "m1.tiny":   0.01,
    "m1.small":  0.03,
    "m1.medium": 0.06,
    "m1.large":  0.12,
    "m1.xlarge": 0.24
  },
  "floating_ip_per_hour":    0.004,
  "load_balancer_per_hour":  0.02,
  "volume_per_gb_hour":      0.0001
}
```

---

## Updated Project Layout

```
mistral-openstack/
├── client.py             # Mistral client factory
├── os_client.py          # OpenStack connection factory
├── rollback.py           # BuildTransaction context manager      ← Phase 13
├── transaction.py        # Module-level transaction singleton    ← Phase 13
├── quota.py              # Quota headroom checks                 ← Phase 15
├── cost.py               # Cost estimator + pricing table        ← Phase 15
├── tools/
│   ├── __init__.py       # Combined TOOLS list and HANDLERS dict
│   ├── compute.py        # Nova: schemas + handlers + parallel create  ← Phase 14
│   ├── network.py        # Neutron: schemas + handlers
│   ├── loadbalancer.py   # Octavia: schemas + handlers
│   └── quota.py          # Quota + cost tool schemas and handlers ← Phase 15
├── agent.py              # Agentic loop with rollback integration
├── stream.py             # Streaming helper
├── mistral-os            # CLI entrypoint
└── requirements.txt
```

`requirements.txt` (updated):

```
mistralai>=1.0.0
openstacksdk>=3.0.0
python-openstackclient>=6.0.0
tenacity>=8.0.0
```

No new dependencies are required — `concurrent.futures` is stdlib, and the quota/cost modules use only openstacksdk calls already present.


---

## Phase 16 — Horizon Dashboard Panel

### Overview

This phase adds a first-class panel to the OpenStack Horizon dashboard that embeds the Mistral AI chat interface directly in the operator UI. Operators can type natural language requests, watch the agent work in real time, and review a build summary — all without leaving the browser or touching a terminal.

The panel is implemented as a standard Horizon plugin: a Python package that registers itself via the `enabled/` mechanism, requiring no modification to Horizon core. It can be installed on any Horizon instance by dropping the package in and adding one enabled file.

#### Component Map

```
horizon-mistral-ai/                  ← installable Python package
│
├── enabled/
│   └── _80_mistral_ai_panel.py      ← registers the panel with Horizon
│
├── mistral_ai_panel/
│   ├── __init__.py
│   ├── panel.py                     ← Horizon Panel class
│   ├── urls.py                      ← URL patterns
│   ├── views.py                     ← Django views (chat page + SSE stream)
│   ├── api.py                       ← thin wrapper calling agent.py
│   └── templates/
│       └── mistral_ai_panel/
│           └── chat.html            ← chat UI template
│
└── setup.cfg / pyproject.toml
```

#### Interaction Flow

```
Browser (Horizon)
    │
    ├─POST /project/mistral-ai/chat/   ← user submits a request
    │       └── views.ChatSubmitView
    │               └── api.run_agent_sse(request_text, session_id)
    │                       └── runs agent loop in background thread
    │                               └── yields SSE events per tool call / final answer
    │
    └─GET  /project/mistral-ai/stream/?session_id=<id>
            └── views.StreamView
                    └── Django StreamingHttpResponse (text/event-stream)
                            └── browser EventSource consumes token-by-token
```

SSE (Server-Sent Events) is used for streaming because it works over a plain HTTP connection, requires no WebSocket upgrade, and is natively supported by every modern browser via `EventSource`. Horizon's existing Nginx configuration does not need changing — just disable proxy buffering for the stream endpoint (shown in Phase 16.6).

---

### 16.1 Package Structure

```bash
mkdir -p horizon-mistral-ai/mistral_ai_panel/templates/mistral_ai_panel
mkdir -p horizon-mistral-ai/enabled
cd horizon-mistral-ai
```

---

### 16.2 Panel Registration (`enabled/`)

```python
# enabled/_80_mistral_ai_panel.py
#
# Pluggable settings file — Horizon loads this at startup.
# Drop into openstack_dashboard/local/enabled/ on the Horizon host,
# or include it via the installed package (see setup.cfg).

# The slug of the panel to add
PANEL = 'mistral_ai'

# Which dashboard to attach to ('project', 'admin', 'identity', ...)
PANEL_DASHBOARD = 'project'

# Which panel group within that dashboard
PANEL_GROUP = 'compute'

# The Python class that defines this panel
ADD_PANEL = 'mistral_ai_panel.panel.MistralAIPanel'

# Make sure Django can find our templates and static files
ADD_INSTALLED_APPS = ['mistral_ai_panel']
```

---

### 16.3 Panel Class

```python
# mistral_ai_panel/panel.py
from django.utils.translation import gettext_lazy as _
import horizon
from openstack_dashboard.dashboards.project import dashboard


class MistralAIPanel(horizon.Panel):
    name  = _("AI Assistant")
    slug  = "mistral_ai"
    # Optional: restrict to specific Keystone roles
    # permissions = ('openstack.roles.member',)

dashboard.Project.register(MistralAIPanel)
```

---

### 16.4 URL Patterns

```python
# mistral_ai_panel/urls.py
from django.urls import path
from mistral_ai_panel import views

urlpatterns = [
    # Main chat page
    path('', views.IndexView.as_view(), name='index'),

    # POST endpoint — accepts a user request, starts the agent, returns session_id
    path('chat/', views.ChatSubmitView.as_view(), name='chat'),

    # GET endpoint — SSE stream for a given session
    path('stream/', views.StreamView.as_view(), name='stream'),
]
```

---

### 16.5 Views

The views handle three responsibilities:

- `IndexView` — renders the chat page template
- `ChatSubmitView` — accepts the POST, starts the agent in a background thread, returns `session_id`
- `StreamView` — returns a `StreamingHttpResponse` that yields SSE events as the agent produces them

A simple in-process queue per `session_id` bridges the background agent thread and the SSE response. For a multi-worker Gunicorn/uWSGI deployment the queue must move to Redis (see Phase 16.7).

```python
# mistral_ai_panel/views.py
import json
import queue
import threading
import uuid

from django.http import JsonResponse, StreamingHttpResponse
from django.utils.decorators import method_decorator
from django.views import View
from django.views.decorators.csrf import csrf_exempt
from django.shortcuts import render

# In-process session store: session_id → Queue
# Replace with Redis-backed store for multi-worker deployments (see Phase 16.7)
_SESSION_QUEUES: dict[str, queue.Queue] = {}
_SESSION_LOCK = threading.Lock()

# Sentinel value written to the queue when the agent finishes
_DONE = object()


def _get_or_create_queue(session_id: str) -> queue.Queue:
    with _SESSION_LOCK:
        if session_id not in _SESSION_QUEUES:
            _SESSION_QUEUES[session_id] = queue.Queue()
        return _SESSION_QUEUES[session_id]


def _cleanup_session(session_id: str) -> None:
    with _SESSION_LOCK:
        _SESSION_QUEUES.pop(session_id, None)


class IndexView(View):
    """Render the main chat page."""
    template_name = "mistral_ai_panel/chat.html"

    def get(self, request):
        return render(request, self.template_name, {
            "page_title": "AI Infrastructure Assistant",
        })


@method_decorator(csrf_exempt, name='dispatch')
class ChatSubmitView(View):
    """
    Accept a POST with {"request": "...", "model": "..."} and start the agent.
    Returns {"session_id": "<uuid>"} immediately.
    The client then opens an EventSource to /stream/?session_id=<uuid>.
    """

    def post(self, request):
        try:
            body = json.loads(request.body)
        except (json.JSONDecodeError, AttributeError):
            return JsonResponse({"error": "Invalid JSON"}, status=400)

        user_request = body.get("request", "").strip()
        model        = body.get("model", "mistral-small-latest")

        if not user_request:
            return JsonResponse({"error": "request field is required"}, status=400)

        session_id = str(uuid.uuid4())
        q = _get_or_create_queue(session_id)

        # Run the agent in a background thread so the HTTP response returns immediately
        t = threading.Thread(
            target=_run_agent_thread,
            args=(user_request, model, q, session_id),
            daemon=True,
        )
        t.start()

        return JsonResponse({"session_id": session_id})


def _run_agent_thread(
    user_request: str,
    model: str,
    q: queue.Queue,
    session_id: str,
) -> None:
    """
    Runs the Mistral agent and pushes SSE-formatted events into the queue.
    The StreamView drains this queue and sends to the browser.
    """
    # Import here to avoid circular imports and to keep Horizon's import
    # chain clean — the agent module lives in the mistral-openstack package
    # installed alongside this panel.
    try:
        from mistral_openstack.agent import run_agent_with_callback
        from mistral_openstack.rollback import BuildTransaction
        from mistral_openstack.transaction import set_transaction

        tx = BuildTransaction()
        set_transaction(tx)

        def on_event(event_type: str, data: dict) -> None:
            """Called by the agent for each tool call and final answer."""
            q.put(json.dumps({"type": event_type, **data}))

        try:
            run_agent_with_callback(
                user_request=user_request,
                model=model,
                on_event=on_event,
                require_confirm=False,   # no interactive confirm in web UI
            )
            tx.commit()
            q.put(json.dumps({"type": "done", "session_id": session_id}))

        except Exception as exc:
            tx.rollback()
            q.put(json.dumps({
                "type": "error",
                "message": str(exc),
                "rollback": "Resources created before the failure have been rolled back.",
            }))

    finally:
        set_transaction(None)
        q.put(_DONE)


class StreamView(View):
    """
    SSE stream endpoint.  The browser connects here with EventSource after
    receiving a session_id from ChatSubmitView.

    Each event is a JSON object with a "type" field:
        tool_call   — agent is calling an OpenStack tool
        tool_result — tool returned a result
        message     — intermediate text from the agent
        done        — agent has finished (final answer in "content")
        error       — agent failed (message + rollback info)
    """

    def get(self, request):
        session_id = request.GET.get("session_id", "")
        if not session_id:
            return JsonResponse({"error": "session_id required"}, status=400)

        q = _get_or_create_queue(session_id)

        def event_generator():
            try:
                while True:
                    try:
                        item = q.get(timeout=30)  # 30s timeout guards against hung agents
                    except queue.Empty:
                        # Send a keep-alive comment so the browser doesn't time out
                        yield ": keep-alive\n\n"
                        continue

                    if item is _DONE:
                        break

                    # SSE format: "data: <json>\n\n"
                    yield f"data: {item}\n\n"

            finally:
                _cleanup_session(session_id)

        response = StreamingHttpResponse(
            event_generator(),
            content_type="text/event-stream",
        )
        # Prevent Nginx and Django middleware from buffering the stream
        response["X-Accel-Buffering"] = "no"
        response["Cache-Control"]     = "no-cache"
        response["Connection"]        = "keep-alive"
        return response
```

#### Agent Callback Adapter

The existing `run_agent()` in `agent.py` needs a small addition — a callback variant that fires an event for each tool call and tool result rather than printing to stdout. Add `run_agent_with_callback()` alongside the existing function:

```python
# agent.py — add this function

def run_agent_with_callback(
    user_request: str,
    model: str,
    on_event,           # callable(event_type: str, data: dict)
    require_confirm: bool = False,
) -> None:
    """
    Agent loop variant used by the Horizon panel.
    Instead of printing to stdout, fires on_event() for each significant step.
    """
    client   = get_mistral_client()
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user",   "content": user_request},
    ]

    on_event("message", {"content": f"Processing: {user_request}"})

    while True:
        response = client.chat.complete(
            model=model,
            messages=messages,
            tools=TOOLS,
            tool_choice="auto",
        )

        msg = response.choices[0].message
        messages.append(msg)

        if not msg.tool_calls:
            # Final answer
            on_event("done", {"content": msg.content})
            break

        for call in msg.tool_calls:
            fn_name = call.function.name
            fn_args = json.loads(call.function.arguments)

            on_event("tool_call", {"tool": fn_name, "args": fn_args})

            handler = HANDLERS.get(fn_name)
            if not handler:
                result = f"ERROR: Unknown tool '{fn_name}'."
            else:
                try:
                    result = handler(**fn_args)
                except Exception as exc:
                    result = f"ERROR in {fn_name}: {exc}"
                    on_event("error", {"tool": fn_name, "message": str(exc)})

            on_event("tool_result", {"tool": fn_name, "result": result})

            messages.append({
                "role":        "tool",
                "tool_call_id": call.id,
                "content":     result,
            })
```

---

### 16.6 Chat Template

The template uses vanilla JavaScript with `EventSource` — no framework dependency, no build step, compatible with Horizon's existing static asset pipeline.

```html
<!-- mistral_ai_panel/templates/mistral_ai_panel/chat.html -->
{% extends 'base.html' %}
{% load i18n %}

{% block title %}{% trans "AI Infrastructure Assistant" %}{% endblock %}

{% block page_header %}
  {% include "horizon/common/_page_header.html" with title=_("AI Infrastructure Assistant") %}
{% endblock %}

{% block main %}
<div class="row">
  <div class="col-sm-12">

    <!-- Model selector -->
    <div class="panel panel-default" style="margin-bottom:10px;">
      <div class="panel-body" style="padding:10px;">
        <label for="model-select" style="margin-right:8px;">{% trans "Model" %}:</label>
        <select id="model-select" class="form-control" style="display:inline-width:auto;width:280px;">
          <option value="mistral-small-latest">mistral-small-latest (fast)</option>
          <option value="mistral-large-latest">mistral-large-latest (complex builds)</option>
          <option value="codestral-latest">codestral-latest (config / code)</option>
        </select>
      </div>
    </div>

    <!-- Chat history -->
    <div id="chat-history"
         style="background:#1e1e1e;color:#d4d4d4;font-family:monospace;font-size:13px;
                height:480px;overflow-y:auto;padding:16px;border-radius:4px;
                margin-bottom:12px;white-space:pre-wrap;word-break:break-word;">
      <span style="color:#6a9955;">{% trans "# Mistral AI OpenStack Assistant ready." %}</span>
      <span style="color:#6a9955;">{% trans "# Type a request below and press Send." %}</span>

    </div>

    <!-- Input area -->
    <div class="input-group">
      <textarea id="user-input" class="form-control"
                rows="3"
                placeholder="{% trans 'e.g. Create 3 web instances behind an HTTP load balancer called web-lb' %}"
                style="resize:vertical;font-family:monospace;font-size:13px;"></textarea>
      <span class="input-group-btn" style="vertical-align:bottom;">
        <button id="send-btn" class="btn btn-primary" style="height:100%;padding:0 20px;">
          {% trans "Send" %}
        </button>
      </span>
    </div>

    <!-- Status bar -->
    <div id="status-bar"
         style="margin-top:8px;font-size:12px;color:#888;min-height:20px;">
    </div>

  </div>
</div>

<script>
(function () {
  "use strict";

  const history   = document.getElementById("chat-history");
  const input     = document.getElementById("user-input");
  const sendBtn   = document.getElementById("send-btn");
  const statusBar = document.getElementById("status-bar");
  const modelSel  = document.getElementById("model-select");

  // ── Colour scheme (VS Code Dark+ inspired) ────────────────────────────────
  const COLOURS = {
    user:        "#569cd6",   // blue    — user messages
    tool_call:   "#dcdcaa",   // yellow  — tool calls (function names)
    tool_result: "#9cdcfe",   // light blue — tool results
    message:     "#d4d4d4",   // white   — agent prose
    done:        "#4ec9b0",   // teal    — final answer
    error:       "#f44747",   // red     — errors
    meta:        "#6a9955",   // green   — system comments
  };

  let currentSource = null;  // active EventSource

  function append(text, colour, prefix) {
    const span = document.createElement("span");
    span.style.color = colour;
    span.textContent = (prefix ? prefix + " " : "") + text + "\n";
    history.appendChild(span);
    history.scrollTop = history.scrollHeight;
  }

  function setStatus(text) {
    statusBar.textContent = text;
  }

  function setBusy(busy) {
    sendBtn.disabled = busy;
    input.disabled   = busy;
    setStatus(busy ? "Agent is working…" : "");
  }

  async function sendRequest() {
    const text  = input.value.trim();
    const model = modelSel.value;
    if (!text) return;

    // Close any existing stream
    if (currentSource) {
      currentSource.close();
      currentSource = null;
    }

    append("", COLOURS.meta, "");
    append("You: " + text, COLOURS.user, "▶");
    input.value = "";
    setBusy(true);

    // 1. POST the request to get a session_id
    let sessionId;
    try {
      const resp = await fetch("{% url 'horizon:project:mistral_ai:chat' %}", {
        method: "POST",
        headers: {"Content-Type": "application/json",
                  "X-CSRFToken": getCookie("csrftoken")},
        body: JSON.stringify({request: text, model: model}),
      });
      const data = await resp.json();
      if (data.error) {
        append("Error: " + data.error, COLOURS.error, "✗");
        setBusy(false);
        return;
      }
      sessionId = data.session_id;
    } catch (err) {
      append("Network error: " + err.message, COLOURS.error, "✗");
      setBusy(false);
      return;
    }

    // 2. Open SSE stream
    const streamUrl = "{% url 'horizon:project:mistral_ai:stream' %}?session_id=" + sessionId;
    currentSource = new EventSource(streamUrl);

    currentSource.onmessage = function (e) {
      let event;
      try {
        event = JSON.parse(e.data);
      } catch (_) {
        return;
      }

      switch (event.type) {
        case "tool_call":
          append(
            "[" + event.tool + "] " + JSON.stringify(event.args, null, 0),
            COLOURS.tool_call, "⚙"
          );
          setStatus("Calling " + event.tool + "…");
          break;

        case "tool_result":
          // Show a truncated result — full detail is in the agent log
          const preview = (event.result || "").substring(0, 200).replace(/\n/g, " ");
          append("[" + event.tool + "] → " + preview + (event.result.length > 200 ? "…" : ""),
                 COLOURS.tool_result, "↩");
          break;

        case "message":
          append(event.content, COLOURS.message, "·");
          break;

        case "done":
          append("", COLOURS.meta, "");
          append(event.content, COLOURS.done, "✓");
          currentSource.close();
          setBusy(false);
          break;

        case "error":
          append("Error: " + event.message, COLOURS.error, "✗");
          if (event.rollback) {
            append(event.rollback, COLOURS.meta, "↺");
          }
          currentSource.close();
          setBusy(false);
          break;
      }
    };

    currentSource.onerror = function () {
      append("Stream connection lost.", COLOURS.error, "✗");
      currentSource.close();
      setBusy(false);
    };
  }

  // ── Event bindings ─────────────────────────────────────────────────────────
  sendBtn.addEventListener("click", sendRequest);

  input.addEventListener("keydown", function (e) {
    // Ctrl+Enter or Cmd+Enter to send
    if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
      e.preventDefault();
      sendRequest();
    }
  });

  // ── CSRF helper ────────────────────────────────────────────────────────────
  function getCookie(name) {
    const value = "; " + document.cookie;
    const parts = value.split("; " + name + "=");
    if (parts.length === 2) return parts.pop().split(";").shift();
    return "";
  }

})();
</script>
{% endblock %}
```

---

### 16.7 Package Metadata

```toml
# pyproject.toml
[build-system]
requires      = ["pbr>=6.0.0"]
build-backend = "pbr.build"

[project]
name            = "horizon-mistral-ai"
description     = "Mistral AI assistant panel for OpenStack Horizon"
requires-python = ">=3.10"
dynamic         = ["version", "dependencies"]
classifiers     = [
    "Environment :: OpenStack",
    "Framework :: Django",
    "License :: OSI Approved :: Apache Software License",
]
```

```ini
# setup.cfg
[metadata]
name    = horizon-mistral-ai
version = 1.0.0
summary = Mistral AI assistant panel for OpenStack Horizon

[files]
packages = mistral_ai_panel

[options]
install_requires =
    mistral-openstack>=1.0.0
    horizon>=25.0.0

[entry_points]
openstack_dashboard_config =
    mistral_ai = mistral_ai_panel.enabled
```

---

### 16.8 Installation

#### On the Horizon Host

```bash
# Install the panel package into Horizon's Python environment
pip install ./horizon-mistral-ai

# Or from a local directory during development:
pip install -e ./horizon-mistral-ai

# Copy the enabled file into Horizon's local override directory
cp horizon-mistral-ai/enabled/_80_mistral_ai_panel.py \
   /opt/stack/openstack-dashboard/openstack_dashboard/local/enabled/

# Collect static assets
cd /opt/stack/openstack-dashboard
python manage.py collectstatic --noinput

# Restart Horizon (adjust for your init system)
sudo systemctl restart apache2
# or
sudo systemctl restart gunicorn-horizon
```

#### Credentials for the Panel Process

The Horizon process needs the Mistral API key and OpenStack credentials in its environment. Add to the Apache/Gunicorn environment or to `local_settings.py`:

```python
# /opt/stack/openstack-dashboard/openstack_dashboard/local/local_settings.py
import os
os.environ.setdefault("MISTRAL_API_KEY", "your-la-plateforme-api-key")

# The panel uses the currently-logged-in user's Keystone token for OpenStack
# calls, extracted from the Horizon session (see Phase 16.9).
```

---

### 16.9 Using the Logged-In User's Keystone Token

Rather than embedding a service account credential in the panel process, the preferred approach is to extract the logged-in operator's Keystone token from the Horizon session and use it for OpenStack SDK calls. This means the AI assistant operates with exactly the same permissions as the user viewing the panel — no privilege escalation, full audit trail in Keystone.

```python
# mistral_ai_panel/api.py
import openstack


def get_conn_from_request(request) -> openstack.connection.Connection:
    """
    Build an OpenStack SDK connection using the Horizon session token.
    Horizon stores the auth token and endpoint catalog in the request object.
    """
    token    = request.user.token.id
    auth_url = request.user.endpoint

    return openstack.connect(
        auth_type="token",
        auth=dict(
            auth_url=auth_url,
            token=token,
            project_id=request.user.tenant_id,
        ),
        identity_api_version=3,
    )
```

Pass this connection into the agent via a context variable rather than relying on the environment-based `get_conn()`:

```python
# In os_client.py — add token-auth variant
_REQUEST_CONN = threading.local()

def set_request_conn(conn) -> None:
    _REQUEST_CONN.conn = conn

def get_conn():
    # If a per-request connection has been set (Horizon context), use it.
    # Otherwise fall back to environment-variable auth (CLI context).
    return getattr(_REQUEST_CONN, "conn", None) or openstack.connect()
```

In `views.py`, before starting the agent thread:

```python
conn = get_conn_from_request(request)
# Pass conn to the thread via a closure or thread-local
```

---

### 16.10 Nginx Configuration for SSE

Nginx by default buffers proxy responses. SSE requires buffering to be disabled for the stream endpoint, otherwise events are held until the buffer fills and the browser receives them in large batches rather than one at a time.

Add to the Horizon `server {}` block:

```nginx
# /etc/nginx/sites-available/horizon (or equivalent)

# Disable proxy buffering for the SSE stream endpoint only
location /project/mistral-ai/stream/ {
    proxy_pass         http://horizon_backend;
    proxy_buffering    off;
    proxy_cache        off;
    proxy_read_timeout 600s;   # long timeout — SSE connections are long-lived

    # Required headers for SSE
    proxy_set_header Connection '';
    proxy_http_version 1.1;
    chunked_transfer_encoding on;
}
```

If Horizon is served directly by Gunicorn/uWSGI without Nginx in front:

```ini
# Gunicorn: worker timeout must be longer than the longest expected build
# /etc/gunicorn/horizon.conf.py
timeout = 600
worker_class = "gthread"
threads = 4
```

---

### 16.11 Multi-Worker SSE (Redis-Backed Queue)

The in-process `queue.Queue` in `views.py` only works when the agent thread and the SSE stream response are handled by the same Gunicorn worker process. With multiple workers (the production default), a POST may land on worker A while the subsequent GET for `/stream/` lands on worker B — which has no queue for that `session_id`.

The fix is a Redis-backed channel per `session_id`:

```bash
pip install redis
```

```python
# mistral_ai_panel/session_bus.py
"""
Redis-backed pub/sub bus for SSE sessions.
Each agent run publishes to channel "mistral-session:<session_id>".
The SSE view subscribes and forwards to the browser.
"""
import json
import redis
import os

REDIS_URL = os.environ.get("MISTRAL_OS_REDIS_URL", "redis://localhost:6379/0")

def get_redis() -> redis.Redis:
    return redis.from_url(REDIS_URL, decode_responses=True)


def publish(session_id: str, event: dict) -> None:
    r = get_redis()
    r.publish(f"mistral-session:{session_id}", json.dumps(event))


def subscribe(session_id: str):
    """
    Generator that yields raw JSON strings from the Redis channel.
    Stops when it receives a 'done' or 'error' event, or times out.
    """
    r    = get_redis()
    pubsub = r.pubsub()
    pubsub.subscribe(f"mistral-session:{session_id}")

    try:
        for message in pubsub.listen():
            if message["type"] != "message":
                continue
            yield message["data"]
            data = json.loads(message["data"])
            if data.get("type") in ("done", "error"):
                break
    finally:
        pubsub.unsubscribe()
        pubsub.close()
```

Replace the `queue.Queue` calls in `views.py` with `publish()` in the agent thread and `subscribe()` in `StreamView`. Add `MISTRAL_OS_REDIS_URL` to the Horizon environment.

---

### 16.12 What the Panel Looks Like

When an operator navigates to **Project → AI Assistant** in Horizon they see:

```
┌─────────────────────────────────────────────────────────────────┐
│  AI Infrastructure Assistant                    [Model ▾]       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  # Mistral AI OpenStack Assistant ready.                        │
│  # Type a request below and press Send.                         │
│                                                                  │
│  ▶ You: Create 3 web instances behind an HTTP load balancer     │
│                                                                  │
│  · Processing request…                                          │
│  ⚙ [list_images] {}                                            │
│  ↩ [list_images] → [{"name": "ubuntu-22.04", ...}]             │
│  ⚙ [list_flavours] {}                                          │
│  ↩ [list_flavours] → [{"name": "m1.small", ...}]               │
│  ⚙ [check_quota_headroom] {"instance_count": 3, ...}           │
│  ↩ [check_quota_headroom] → {"feasible": true, ...}            │
│  ⚙ [estimate_cost] {"instance_specs": [...], ...}              │
│  ↩ [estimate_cost] → {"total_estimated_cost": 83.22, ...}      │
│  ⚙ [create_servers_parallel] {"server_specs": [...]}           │
│  ↩ [create_servers_parallel] → [{"name": "web-01", ...}]       │
│  ⚙ [create_load_balancer] {"name": "web-lb", ...}              │
│  ⚙ [wait_for_load_balancer] {"lb_id": "abc123"}                │
│  ⚙ [create_lb_listener] {"name": "web-lb-listener", ...}       │
│  ⚙ [wait_for_load_balancer] {"lb_id": "abc123"}                │
│  ⚙ [create_lb_pool] {"name": "web-lb-pool", ...}               │
│  ⚙ [create_health_monitor] {"pool_id": "def456", ...}          │
│  ⚙ [create_lb_member] {"name": "web-01", "address": "..."}     │
│  ⚙ [create_lb_member] {"name": "web-02", "address": "..."}     │
│  ⚙ [create_lb_member] {"name": "web-03", "address": "..."}     │
│                                                                  │
│  ✓ Build complete. Created:                                     │
│    Instances: web-01 (192.168.1.101), web-02, web-03            │
│    Load Balancer: web-lb — VIP 10.0.0.50                       │
│    Floating IP: 203.0.113.42 → web-lb                          │
│    Monthly cost estimate: £83.22                                │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│  ┌───────────────────────────────────────────────────┐  [Send] │
│  │ Type a request…  (Ctrl+Enter to send)             │         │
│  └───────────────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

---

### 16.13 Updated Project Layout

```
mistral-openstack/               ← core agent package (Phases 1–15)
│   (unchanged)
│
horizon-mistral-ai/              ← Horizon plugin package (Phase 16)
├── pyproject.toml
├── setup.cfg
├── enabled/
│   └── _80_mistral_ai_panel.py  ← drop into openstack_dashboard/local/enabled/
└── mistral_ai_panel/
    ├── __init__.py
    ├── panel.py                 ← Horizon Panel class
    ├── urls.py                  ← URL patterns
    ├── views.py                 ← IndexView / ChatSubmitView / StreamView
    ├── api.py                   ← Keystone token extraction helper
    ├── session_bus.py           ← Redis-backed SSE bus (multi-worker)
    └── templates/
        └── mistral_ai_panel/
            └── chat.html        ← chat UI
```

`horizon-mistral-ai` depends on `mistral-openstack` (the core package from Phases 1–15). Both are installed into the same Horizon Python environment. The enabled file and a `collectstatic` run are the only changes needed to the Horizon installation itself.

