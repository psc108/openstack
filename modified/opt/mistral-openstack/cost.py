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
