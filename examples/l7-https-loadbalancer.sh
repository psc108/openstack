#!/usr/bin/env bash
# =============================================================================
# L7 HTTP/HTTPS Load Balancer Example for OpenStack Octavia
# =============================================================================
# Creates a Layer 7 (HTTP/HTTPS) load balancer with:
# - HTTP listener with HTTPS redirect policy
# - HTTPS listener with TLS termination
# - Path-based routing (/api/* goes to API pool, rest to default pool)
# - HTTP health monitors with configurable URL paths
# - Cookie-based session persistence
#
# Usage:
#   bash l7-https-loadbalancer.sh
#   
# Prerequisites:
#   - Source your OpenStack credentials (admin-openrc.sh or demo-openrc.sh)
#   - Ensure target subnet and member IPs exist
#   - Backend servers running HTTP services
#   - TLS certificate uploaded to Barbican (see comments below)
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration Variables - Modify these for your environment
# -----------------------------------------------------------------------------
LB_NAME="https-lb-example"
LB_DESCRIPTION="Layer 7 HTTPS Load Balancer with Path Routing"

# Network Configuration  
VIP_SUBNET_NAME="selfservice"  # Subnet where VIP will be allocated
MEMBER_SUBNET_NAME="selfservice"  # Subnet where backend members reside

# Load Balancer Configuration
HTTP_PORT="80"
HTTPS_PORT="443"
LB_ALGORITHM="ROUND_ROBIN"
SESSION_PERSISTENCE="HTTP_COOKIE"

# TLS Configuration (requires Barbican certificate container)
# To create a certificate container:
#   openstack secret store --name tls-cert --payload-content-type "application/octet-stream" --payload-content-encoding base64 --payload "$(base64 -w 0 < server.crt)"
#   openstack secret store --name tls-key --payload-content-type "application/octet-stream" --payload-content-encoding base64 --payload "$(base64 -w 0 < server.key)"  
#   openstack secret container create --name tls-container --type certificate --secret certificate="$(openstack secret list --name tls-cert -f value -c "Secret href")" --secret private_key="$(openstack secret list --name tls-key -f value -c "Secret href")"
TLS_CONTAINER_REF=""  # Set this to your Barbican container reference

# Backend Members - Default Pool (main application)
APP_MEMBER_1_IP="10.0.0.10"
APP_MEMBER_1_PORT="80"
APP_MEMBER_1_NAME="app-server-1"

APP_MEMBER_2_IP="10.0.0.11"
APP_MEMBER_2_PORT="80" 
APP_MEMBER_2_NAME="app-server-2"

# Backend Members - API Pool (/api/* requests)
API_MEMBER_1_IP="10.0.0.20"
API_MEMBER_1_PORT="80"
API_MEMBER_1_NAME="api-server-1"

API_MEMBER_2_IP="10.0.0.21"
API_MEMBER_2_PORT="80"
API_MEMBER_2_NAME="api-server-2"

# Health Monitor Configuration
HEALTH_MONITOR_DELAY="10"
HEALTH_MONITOR_TIMEOUT="5"
HEALTH_MONITOR_MAX_RETRIES="3"
APP_HEALTH_URL="/"           # Health check URL for app servers
API_HEALTH_URL="/api/health" # Health check URL for API servers
EXPECTED_CODES="200,202"     # HTTP codes considered healthy

# =============================================================================
# Helper Functions
# =============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

wait_for_active() {
    local resource_type="$1"
    local resource_id="$2" 
    local max_wait="${3:-300}"
    
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
log "Creating L7 HTTPS Load Balancer: $LB_NAME"

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
# Step 2: Create HTTP Listener (for redirect to HTTPS)
# -----------------------------------------------------------------------------
log "Creating HTTP listener on port $HTTP_PORT (for HTTPS redirect)..."

HTTP_LISTENER_ID=$(openstack loadbalancer listener create \
    --protocol HTTP \
    --protocol-port "$HTTP_PORT" \
    --name "${LB_NAME}-http-listener" \
    "$LB_ID" \
    -f value -c id)

log "HTTP listener created: $HTTP_LISTENER_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 3: Create HTTPS Listener (with TLS termination)
# -----------------------------------------------------------------------------
log "Creating HTTPS listener on port $HTTPS_PORT..."

if [[ -n "$TLS_CONTAINER_REF" ]]; then
    log "Using TLS container: $TLS_CONTAINER_REF"
    HTTPS_LISTENER_ID=$(openstack loadbalancer listener create \
        --protocol TERMINATED_HTTPS \
        --protocol-port "$HTTPS_PORT" \
        --default-tls-container-ref "$TLS_CONTAINER_REF" \
        --name "${LB_NAME}-https-listener" \
        "$LB_ID" \
        -f value -c id)
else
    log "WARNING: No TLS container specified - creating HTTP listener instead"
    log "Set TLS_CONTAINER_REF variable to enable HTTPS termination"
    HTTPS_LISTENER_ID=$(openstack loadbalancer listener create \
        --protocol HTTP \
        --protocol-port "$HTTPS_PORT" \
        --name "${LB_NAME}-https-listener" \
        "$LB_ID" \
        -f value -c id)
fi

log "HTTPS listener created: $HTTPS_LISTENER_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 4: Create Default Pool (main application)
# -----------------------------------------------------------------------------
log "Creating default application pool..."

APP_POOL_ID=$(openstack loadbalancer pool create \
    --protocol HTTP \
    --lb-algorithm "$LB_ALGORITHM" \
    --listener "$HTTPS_LISTENER_ID" \
    --name "${LB_NAME}-app-pool" \
    --session-persistence type="$SESSION_PERSISTENCE" \
    -f value -c id)

log "Application pool created: $APP_POOL_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 5: Create API Pool (for /api/* routing)
# -----------------------------------------------------------------------------
log "Creating API pool (for path-based routing)..."

API_POOL_ID=$(openstack loadbalancer pool create \
    --protocol HTTP \
    --lb-algorithm "$LB_ALGORITHM" \
    --loadbalancer "$LB_ID" \
    --name "${LB_NAME}-api-pool" \
    --session-persistence type="$SESSION_PERSISTENCE" \
    -f value -c id)

log "API pool created: $API_POOL_ID"  
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 6: Add Members to Application Pool
# -----------------------------------------------------------------------------
log "Adding members to application pool..."

APP_MEMBER_1_ID=$(openstack loadbalancer member create \
    --address "$APP_MEMBER_1_IP" \
    --protocol-port "$APP_MEMBER_1_PORT" \
    --subnet-id "$MEMBER_SUBNET_ID" \
    --name "$APP_MEMBER_1_NAME" \
    "$APP_POOL_ID" \
    -f value -c id)

log "App member 1 created: $APP_MEMBER_1_ID"
wait_for_active "show" "$LB_ID"

APP_MEMBER_2_ID=$(openstack loadbalancer member create \
    --address "$APP_MEMBER_2_IP" \
    --protocol-port "$APP_MEMBER_2_PORT" \
    --subnet-id "$MEMBER_SUBNET_ID" \
    --name "$APP_MEMBER_2_NAME" \
    "$APP_POOL_ID" \
    -f value -c id)

log "App member 2 created: $APP_MEMBER_2_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 7: Add Members to API Pool
# -----------------------------------------------------------------------------
log "Adding members to API pool..."

API_MEMBER_1_ID=$(openstack loadbalancer member create \
    --address "$API_MEMBER_1_IP" \
    --protocol-port "$API_MEMBER_1_PORT" \
    --subnet-id "$MEMBER_SUBNET_ID" \
    --name "$API_MEMBER_1_NAME" \
    "$API_POOL_ID" \
    -f value -c id)

log "API member 1 created: $API_MEMBER_1_ID"
wait_for_active "show" "$LB_ID"

API_MEMBER_2_ID=$(openstack loadbalancer member create \
    --address "$API_MEMBER_2_IP" \
    --protocol-port "$API_MEMBER_2_PORT" \
    --subnet-id "$MEMBER_SUBNET_ID" \
    --name "$API_MEMBER_2_NAME" \
    "$API_POOL_ID" \
    -f value -c id)

log "API member 2 created: $API_MEMBER_2_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 8: Create L7 Policy for HTTPS Redirect
# -----------------------------------------------------------------------------
log "Creating HTTPS redirect policy on HTTP listener..."

REDIRECT_POLICY_ID=$(openstack loadbalancer l7policy create \
    --action REDIRECT_PREFIX \
    --redirect-prefix "https://" \
    --position 1 \
    --name "${LB_NAME}-https-redirect" \
    "$HTTP_LISTENER_ID" \
    -f value -c id)

log "HTTPS redirect policy created: $REDIRECT_POLICY_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 9: Create L7 Policy for API Path Routing
# -----------------------------------------------------------------------------
log "Creating API path routing policy..."

API_POLICY_ID=$(openstack loadbalancer l7policy create \
    --action REDIRECT_TO_POOL \
    --redirect-pool-id "$API_POOL_ID" \
    --position 1 \
    --name "${LB_NAME}-api-routing" \
    "$HTTPS_LISTENER_ID" \
    -f value -c id)

log "API routing policy created: $API_POLICY_ID"
wait_for_active "show" "$LB_ID"

# Create L7 rule for /api/* path matching
log "Creating L7 rule for /api/* path matching..."

API_RULE_ID=$(openstack loadbalancer l7rule create \
    --type PATH \
    --compare-type STARTS_WITH \
    --value "/api" \
    "$API_POLICY_ID" \
    -f value -c id)

log "API path rule created: $API_RULE_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Step 10: Create Health Monitors
# -----------------------------------------------------------------------------
log "Creating health monitor for application pool..."

APP_MONITOR_ID=$(openstack loadbalancer healthmonitor create \
    --type HTTP \
    --delay "$HEALTH_MONITOR_DELAY" \
    --timeout "$HEALTH_MONITOR_TIMEOUT" \
    --max-retries "$HEALTH_MONITOR_MAX_RETRIES" \
    --url-path "$APP_HEALTH_URL" \
    --expected-codes "$EXPECTED_CODES" \
    --name "${LB_NAME}-app-monitor" \
    "$APP_POOL_ID" \
    -f value -c id)

log "Application health monitor created: $APP_MONITOR_ID"
wait_for_active "show" "$LB_ID"

log "Creating health monitor for API pool..."

API_MONITOR_ID=$(openstack loadbalancer healthmonitor create \
    --type HTTP \
    --delay "$HEALTH_MONITOR_DELAY" \
    --timeout "$HEALTH_MONITOR_TIMEOUT" \
    --max-retries "$HEALTH_MONITOR_MAX_RETRIES" \
    --url-path "$API_HEALTH_URL" \
    --expected-codes "$EXPECTED_CODES" \
    --name "${LB_NAME}-api-monitor" \
    "$API_POOL_ID" \
    -f value -c id)

log "API health monitor created: $API_MONITOR_ID"
wait_for_active "show" "$LB_ID"

# -----------------------------------------------------------------------------
# Summary and Next Steps
# -----------------------------------------------------------------------------
log "L7 HTTPS Load Balancer deployment complete!"
echo
echo "=== Load Balancer Summary ==="
echo "Name:           $LB_NAME"
echo "ID:             $LB_ID"
echo "VIP Address:    $VIP_ADDRESS"
echo "HTTP Port:      $HTTP_PORT (redirects to HTTPS)"
echo "HTTPS Port:     $HTTPS_PORT"
echo "Algorithm:      $LB_ALGORITHM"
echo "Persistence:    $SESSION_PERSISTENCE"
echo
echo "=== Routing Configuration ==="
echo "HTTP :$HTTP_PORT  -> HTTPS redirect"
echo "HTTPS:$HTTPS_PORT -> Default: App Pool"
echo "HTTPS:$HTTPS_PORT -> /api/*: API Pool"
echo
echo "=== Application Pool Members ==="
echo "1. $APP_MEMBER_1_NAME: $APP_MEMBER_1_IP:$APP_MEMBER_1_PORT"
echo "2. $APP_MEMBER_2_NAME: $APP_MEMBER_2_IP:$APP_MEMBER_2_PORT"
echo "   Health check: $APP_HEALTH_URL"
echo
echo "=== API Pool Members ==="
echo "1. $API_MEMBER_1_NAME: $API_MEMBER_1_IP:$API_MEMBER_1_PORT"
echo "2. $API_MEMBER_2_NAME: $API_MEMBER_2_IP:$API_MEMBER_2_PORT" 
echo "   Health check: $API_HEALTH_URL"
echo
echo "=== Health Monitor Settings ==="
echo "Check interval: ${HEALTH_MONITOR_DELAY}s"
echo "Timeout: ${HEALTH_MONITOR_TIMEOUT}s"
echo "Max retries: $HEALTH_MONITOR_MAX_RETRIES"
echo "Expected codes: $EXPECTED_CODES"
echo
echo "=== Next Steps ==="
echo "1. Test HTTP redirect: curl -I http://$VIP_ADDRESS"
echo "2. Test HTTPS (if TLS configured): curl -k https://$VIP_ADDRESS"
echo "3. Test API routing: curl -k https://$VIP_ADDRESS/api/status"
echo "4. Assign floating IP:"
echo "   openstack floating ip create provider"
echo "   openstack floating ip set --port \$(openstack loadbalancer show $LB_ID -f value -c vip_port_id) <floating_ip>"
echo "5. Monitor health:"
echo "   openstack loadbalancer member list $APP_POOL_ID"
echo "   openstack loadbalancer member list $API_POOL_ID"
echo
echo "=== Cleanup Commands ==="
echo "openstack loadbalancer delete $LB_ID"
echo
if [[ -z "$TLS_CONTAINER_REF" ]]; then
    echo "=== TLS Certificate Setup (for HTTPS termination) ==="
    echo "To enable proper HTTPS termination, create a Barbican certificate container:"
    echo
    echo "# Store certificate and key in Barbican"
    echo "openstack secret store --name tls-cert \\"
    echo "  --payload-content-type 'application/octet-stream' \\"
    echo "  --payload-content-encoding base64 \\"
    echo "  --payload \"\$(base64 -w 0 < server.crt)\""
    echo
    echo "openstack secret store --name tls-key \\"
    echo "  --payload-content-type 'application/octet-stream' \\"
    echo "  --payload-content-encoding base64 \\"
    echo "  --payload \"\$(base64 -w 0 < server.key)\""
    echo
    echo "# Create certificate container"
    echo "openstack secret container create --name tls-container \\"
    echo "  --type certificate \\"
    echo "  --secret certificate=\"\$(openstack secret list --name tls-cert -f value -c 'Secret href')\" \\"
    echo "  --secret private_key=\"\$(openstack secret list --name tls-key -f value -c 'Secret href')\""
    echo
    echo "# Update TLS_CONTAINER_REF variable with the container href and re-run script"
fi