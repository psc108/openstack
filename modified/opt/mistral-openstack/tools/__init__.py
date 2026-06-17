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
