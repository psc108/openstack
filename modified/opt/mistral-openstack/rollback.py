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
