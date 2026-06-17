import json
from os_client import get_conn

def get_compute_headroom() -> dict:
    """
    Returns current Nova quota usage and available headroom for the project.
    """
    conn = get_conn()
    limits = conn.compute.get_limits()
    absolute = limits.absolute

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

def check_build_feasibility(
    instance_count: int,
    vcpus_per_instance: int,
    ram_mb_per_instance: int,
    floating_ip_count: int = 0,
    load_balancer_count: int = 0,
) -> dict:
    """
    Check whether the requested build fits within current project quota.
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
