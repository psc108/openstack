"""
Centralized resource finder with fuzzy matching for OpenStack SDK resources.

This module provides a single helper function that can fuzzy-match any OpenStack
resource by name, eliminating the need to duplicate fuzzy matching logic across
all AI tool modules.
"""

import json
from typing import Any, Callable, List, Tuple, Optional


def find_resource_fuzzy(
    conn,
    resource_type: str,
    search_name: str,
    list_func: Callable,
    find_func: Callable,
    filter_func: Optional[Callable[[Any], bool]] = None,
) -> Tuple[Any, str]:
    """
    Find an OpenStack resource with fuzzy name matching.
    
    Args:
        conn: OpenStack connection object
        resource_type: Human-readable resource type for error messages (e.g. "image", "network")
        search_name: User-provided name to search for
        list_func: Function to list all resources (e.g. conn.compute.images)
        find_func: Function to find resource by exact name (e.g. conn.compute.find_image)
        filter_func: Optional additional filter for resources (e.g. lambda x: x.is_router_external)
    
    Returns:
        Tuple of (resource_object, matched_name)
        
    Raises:
        ValueError: If no match found or multiple ambiguous matches
    """
    # Step 1: Try exact match first (fastest path)
    try:
        resource = find_func(search_name, ignore_missing=False)
        return resource, search_name
    except Exception:
        pass  # Fall through to fuzzy matching
    
    # Step 2: Get all resources and apply optional filter
    all_resources = list(list_func())
    if filter_func:
        all_resources = [r for r in all_resources if filter_func(r)]
    
    # Step 3: Normalize search term for fuzzy matching
    search_norm = _normalize_name(search_name)
    
    # Step 4: Find matches using substring search on normalized names
    matches = []
    for resource in all_resources:
        resource_norm = _normalize_name(resource.name)
        if search_norm in resource_norm:
            matches.append(resource)
    
    # Step 5: Handle match results
    if not matches:
        available = [r.name for r in all_resources[:10]]  # Limit to first 10 for readability
        if len(all_resources) > 10:
            available.append(f"... and {len(all_resources) - 10} more")
        raise ValueError(
            f"No {resource_type} found matching '{search_name}'. "
            f"Available: {available}"
        )
    
    if len(matches) > 1:
        match_names = [r.name for r in matches]
        raise ValueError(
            f"Multiple {resource_type}s match '{search_name}': {match_names}. "
            f"Please be more specific."
        )
    
    # Step 6: Single match found
    resource = matches[0]
    print(f"  [fuzzy] Matched '{search_name}' to {resource_type} '{resource.name}'")
    return resource, resource.name


def _normalize_name(name: str) -> str:
    """
    Normalize a resource name for fuzzy matching.
    
    Removes hyphens, underscores, spaces and converts to lowercase.
    This allows 'self-service' to match 'selfservice-subnet'.
    """
    return name.lower().replace("-", "").replace("_", "").replace(" ", "")


def find_resource_fuzzy_safe(
    conn,
    resource_type: str,
    search_name: str,
    list_func: Callable,
    find_func: Callable,
    filter_func: Optional[Callable[[Any], bool]] = None,
) -> dict:
    """
    Safe wrapper around find_resource_fuzzy that returns JSON-serializable results.
    
    Returns:
        dict: Either {"resource": resource, "matched_name": name} on success
              or {"error": error_message, "available": [names]} on failure
    """
    try:
        resource, matched_name = find_resource_fuzzy(
            conn, resource_type, search_name, list_func, find_func, filter_func
        )
        return {
            "resource": resource,
            "matched_name": matched_name
        }
    except ValueError as e:
        # Extract available resources from error message if present
        error_msg = str(e)
        available = []
        if "Available:" in error_msg:
            try:
                available_part = error_msg.split("Available: ")[1]
                available = eval(available_part)  # Parse the list from error message
            except:
                pass
        
        return {
            "error": error_msg,
            "available": available
        }


# Convenience functions for common resource types
def find_image(conn, image_name: str):
    """Find image with fuzzy matching, filtering only active images."""
    return find_resource_fuzzy(
        conn, "image", image_name,
        lambda: conn.image.images(),
        conn.compute.find_image,
        lambda img: img.status == "active"
    )

def find_flavor(conn, flavor_name: str):
    """Find flavor with fuzzy matching."""
    return find_resource_fuzzy(
        conn, "flavor", flavor_name,
        conn.compute.flavors,
        conn.compute.find_flavor
    )

def find_network(conn, network_name: str):
    """Find network with fuzzy matching."""
    return find_resource_fuzzy(
        conn, "network", network_name,
        conn.network.networks,
        conn.network.find_network
    )

def find_external_network(conn, network_name: str):
    """Find external network with fuzzy matching."""
    return find_resource_fuzzy(
        conn, "external network", network_name,
        conn.network.networks,
        conn.network.find_network,
        lambda net: net.is_router_external
    )

def find_subnet(conn, subnet_name: str):
    """Find subnet with fuzzy matching."""
    return find_resource_fuzzy(
        conn, "subnet", subnet_name,
        conn.network.subnets,
        conn.network.find_subnet
    )

def find_server(conn, server_name: str):
    """Find server with fuzzy matching."""
    return find_resource_fuzzy(
        conn, "server", server_name,
        conn.compute.servers,
        conn.compute.find_server
    )

def find_load_balancer(conn, lb_name: str):
    """Find load balancer with fuzzy matching."""
    return find_resource_fuzzy(
        conn, "load balancer", lb_name,
        conn.load_balancer.load_balancers,
        conn.load_balancer.find_load_balancer
    )