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
