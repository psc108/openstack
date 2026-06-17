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
