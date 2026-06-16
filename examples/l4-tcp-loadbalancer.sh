#!/usr/bin/env bash
# =============================================================================
# L4 TCP Load Balancer Example for OpenStack Octavia
# =============================================================================
# Creates a Layer 4 (TCP) load balancer with:
# - TCP listener on configurable port
# - Round-robin pool with SOURCE_IP session persistence
# - TCP health monitor (connection-based)
# - Two backend members with configurable IPs and ports
#
# Usage:
#   bash l4-tcp-loadbalancer.sh
#   
# Prerequisites:
#   - Source your OpenStack credentials (admin-openrc.sh or demo-openrc.sh)
#   - Ensure target subnet and member IPs exist
#   - Backend servers running and listening on specified ports
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration Variables - Modify these for your environment
# -----------------------------------------------------------------------------
LB_NAME="tcp-lb-example"
LB_DESCRIPTION="Layer 4 TCP Load Balancer Example"

# Network Configuration
VIP_SUBNET_NAME="selfservice"  # Subnet where VIP will be allocated
MEMBER_SUBNET_NAME="selfservice"  # Subnet where backend members reside

# Load Balancer Configuration
LISTENER_PORT="80"
POOL_PROTOCOL="TCP"
LB_ALGORITHM="ROUND_ROBIN"
SESSION_PERSISTENCE="SOURCE_IP"

# Backend Members
MEMBER_1_IP="10.0.0.10"
MEMBER_1_PORT="80"
MEMBER_1_NAME="web-server-1"

MEMBER_2_IP="10.0.0.11" 
MEMBER_2_PORT="80"
MEMBER_2_NAME="web-server-2"

# Health Monitor Configuration
HEALTH_MONITOR_TYPE="TCP"
HEALTH_MONITOR_DELAY="5"     # seconds between checks
HEALTH_MONITOR_TIMEOUT="3"   # seconds to wait for response
HEALTH_MONITOR_MAX_RETRIES="3"  # retries before marking down

# =============================================================================
# Helper Functions
# =============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

wait_for_active() {
    local resource_type="$1"
    local resource_id="$2"
    local max_wait="${3:-300}"  # Default 5 minutes
    
    log "Waiting for $resource_type $resource_id to become ACTIVE..."
    
    local count=0
    while [ $count -lt $max_wait ]; do
        local status
        status=$(openstack loadbalancer "$resource_type" show "$resource_id" -f value -c provisioning_status 2>/dev/null || echo "ERROR")
        
        case "$status" in
            "ACTIVE")
                log "$resource_type $resource_id is ACTIVE"
                return 0
                ;;
            "ERROR")
                log "ERROR: $resource_type $resource_id failed"
                return 1
                ;;
            "PENDING_CREATE"|"PENDING_UPDATE")
                sleep 2
                ((count += 2))
                ;;
            *)
                log "Unknown status: $status"
                sleep 2
                ((count += 2))
                ;;
        esac
    done
    
    log "ERROR: $resource_type $resource_id did not become ACTIVE within $max_wait seconds"
    return 1
}

# =============================================================================
# Main Script
# =============================================================================
log "Creating L4 TCP Load Balancer: $LB_NAME"

# Check prerequisites
if ! openstack network show "$VIP_SUBNET_NAME" >/dev/null 2>&1; then
    log "ERROR: VIP subnet '$VIP_SUBNET_NAME' not found"
    exit 1
fi

if ! openstack network show "$MEMBER_SUBNET_NAME" >/dev/null 2>&1; then
    log "ERROR: Member subnet '$MEMBER_SUBNET_NAME' not found"
    exit 1
fi

# Get subnet IDs
VIP_SUBNET_ID=$(openstack subnet show "$VIP_SUBNET_NAME" -f value -c id)
MEMBER_SUBNET_ID=$(openstack subnet show "$MEMBER_SUBNET_NAME" -f value -c id)

log "VIP Subnet: $VIP_SUBNET_NAME ($VIP_SUBNET_ID)"
log "Member Subnet: $MEMBER_SUBNET_NAME ($MEMBER_SUBNET_ID)"

# -----------------------------------------------------------------------------
# Step 1: Create Load Balancer
# -----------------------------------------------------------------------------
log "Creating load balancer..."

LB_ID=$(openstack loadbalancer create \
    --vip-subnet-id "$VIP_SUBNET_ID" \
    --name "$LB_NAME" \
    --description "$LB_DESCRIPTION" \
    -f value -c id)

log "Load balancer created: $LB_ID"
wait_for_active "show" "$LB_ID"

# Get VIP address for reference
VIP_ADDRESS=$(openstack loadbalancer show "$LB_ID" -f value -c vip_address)
log "VIP Address: $VIP_ADDRESS"

# -----------------------------------------------------------------------------
# Step 2: Create Listener
# -----------------------------------------------------------------------------
log "Creating TCP listener on port $LISTENER_PORT..."

LISTENER_ID=$(openstack loadbalancer listener create \
    --protocol TCP \
    --protocol-port "$LISTENER_PORT" \
    --name "${LB_NAME}-listener" \
    "$LB_ID" \
    -f value -c id)

log "Listener created: $LISTENER_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 3: Create Pool
# -----------------------------------------------------------------------------
log "Creating pool with $LB_ALGORITHM algorithm and $SESSION_PERSISTENCE persistence..."

POOL_ID=$(openstack loadbalancer pool create \
    --protocol "$POOL_PROTOCOL" \
    --lb-algorithm "$LB_ALGORITHM" \
    --listener "$LISTENER_ID" \
    --name "${LB_NAME}-pool" \
    --session-persistence type="$SESSION_PERSISTENCE" \
    -f value -c id)

log "Pool created: $POOL_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 4: Add Pool Members
# -----------------------------------------------------------------------------
log "Adding pool member: $MEMBER_1_NAME ($MEMBER_1_IP:$MEMBER_1_PORT)..."

MEMBER_1_ID=$(openstack loadbalancer member create \
    --address "$MEMBER_1_IP" \
    --protocol-port "$MEMBER_1_PORT" \
    --subnet-id "$MEMBER_SUBNET_ID" \
    --name "$MEMBER_1_NAME" \
    "$POOL_ID" \
    -f value -c id)

log "Member 1 created: $MEMBER_1_ID"
wait_for_active "show" "$LB_ID"

log "Adding pool member: $MEMBER_2_NAME ($MEMBER_2_IP:$MEMBER_2_PORT)..."

MEMBER_2_ID=$(openstack loadbalancer member create \
    --address "$MEMBER_2_IP" \
    --protocol-port "$MEMBER_2_PORT" \
    --subnet-id "$MEMBER_SUBNET_ID" \
    --name "$MEMBER_2_NAME" \
    "$POOL_ID" \
    -f value -c id)

log "Member 2 created: $MEMBER_2_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 5: Create Health Monitor
# -----------------------------------------------------------------------------
log "Creating $HEALTH_MONITOR_TYPE health monitor (delay:${HEALTH_MONITOR_DELAY}s, timeout:${HEALTH_MONITOR_TIMEOUT}s, retries:$HEALTH_MONITOR_MAX_RETRIES)..."

MONITOR_ID=$(openstack loadbalancer healthmonitor create \
    --type "$HEALTH_MONITOR_TYPE" \
    --delay "$HEALTH_MONITOR_DELAY" \
    --timeout "$HEALTH_MONITOR_TIMEOUT" \
    --max-retries "$HEALTH_MONITOR_MAX_RETRIES" \
    --name "${LB_NAME}-monitor" \
    "$POOL_ID" \
    -f value -c id)

log "Health monitor created: $MONITOR_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Summary and Next Steps
# -----------------------------------------------------------------------------
log "L4 TCP Load Balancer deployment complete!"
echo
echo "=== Load Balancer Summary ==="
echo "Name:        $LB_NAME"
echo "ID:          $LB_ID"  
echo "VIP Address: $VIP_ADDRESS"
echo "Protocol:    TCP:$LISTENER_PORT"
echo "Algorithm:   $LB_ALGORITHM"
echo "Persistence: $SESSION_PERSISTENCE"
echo
echo "=== Backend Members ==="
echo "1. $MEMBER_1_NAME: $MEMBER_1_IP:$MEMBER_1_PORT"
echo "2. $MEMBER_2_NAME: $MEMBER_2_IP:$MEMBER_2_PORT"
echo
echo "=== Health Monitor ==="
echo "Type: $HEALTH_MONITOR_TYPE"
echo "Check interval: ${HEALTH_MONITOR_DELAY}s"
echo "Timeout: ${HEALTH_MONITOR_TIMEOUT}s"
echo "Max retries: $HEALTH_MONITOR_MAX_RETRIES"
echo
echo "=== Next Steps ==="
echo "1. Test connectivity: telnet $VIP_ADDRESS $LISTENER_PORT"
echo "2. Assign floating IP (optional):"
echo "   openstack floating ip create provider"
echo "   openstack floating ip set --port \$(openstack loadbalancer show $LB_ID -f value -c vip_port_id) <floating_ip>"
echo "3. Monitor status:"
echo "   openstack loadbalancer show $LB_ID"
echo "   openstack loadbalancer member list $POOL_ID"
echo
echo "=== Cleanup Command ==="
echo "openstack loadbalancer delete $LB_ID"