# OpenStack Octavia Load Balancer Examples

This directory contains practical examples for creating load balancers using OpenStack Octavia via the CLI.

## Available Examples

### L4 TCP Load Balancer (`l4-tcp-loadbalancer.sh`)

**Use Case**: Database clusters, message queues, generic TCP services, high-performance applications

**Features**:
- Layer 4 (TCP) load balancing - protocol agnostic
- Round-robin distribution with SOURCE_IP session persistence  
- TCP health monitoring (connection-based)
- Two configurable backend members
- Simple, high-performance setup

**Configuration Variables**:
```bash
LB_NAME="tcp-lb-example"
VIP_SUBNET_NAME="selfservice"      # Where VIP is allocated
MEMBER_SUBNET_NAME="selfservice"   # Where backends reside
LISTENER_PORT="80"                 # Frontend port
MEMBER_1_IP="10.0.0.10"           # Backend server 1
MEMBER_2_IP="10.0.0.11"           # Backend server 2
```

### L7 HTTP/HTTPS Load Balancer (`l7-https-loadbalancer.sh`)

**Use Case**: Web applications, REST APIs, microservices with path-based routing

**Features**:
- HTTP to HTTPS redirect (port 80 → 443)
- HTTPS termination with Barbican TLS certificates
- Path-based routing (`/api/*` → dedicated API pool)
- HTTP health monitoring with configurable endpoints
- Cookie-based session persistence
- Two backend pools (app and API servers)

**Configuration Variables**:
```bash
LB_NAME="https-lb-example"
TLS_CONTAINER_REF=""               # Barbican certificate container
APP_MEMBER_1_IP="10.0.0.10"       # App server 1  
API_MEMBER_1_IP="10.0.0.20"       # API server 1
APP_HEALTH_URL="/"                 # App health endpoint
API_HEALTH_URL="/api/health"       # API health endpoint
```

## Prerequisites

1. **OpenStack Environment**: Working Octavia installation with amphora images
2. **Authentication**: Source your credentials (`source /root/admin-openrc.sh`)
3. **Network Setup**: Ensure subnets exist and backend IPs are reachable
4. **Backend Services**: Servers running and listening on configured ports

## Usage

### Basic Usage
```bash
# Edit configuration variables at top of script
vim l4-tcp-loadbalancer.sh

# Run the script
bash l4-tcp-loadbalancer.sh
```

### For HTTPS Load Balancer
```bash
# 1. Create TLS certificate container in Barbican (see TLS setup below)
# 2. Edit script and set TLS_CONTAINER_REF variable
# 3. Configure backend IPs and health check URLs
# 4. Run script
bash l7-https-loadbalancer.sh
```

## TLS Certificate Setup (for L7 HTTPS)

To enable HTTPS termination, you need a Barbican certificate container:

```bash
# Store certificate and private key in Barbican
openstack secret store --name tls-cert \
  --payload-content-type 'application/octet-stream' \
  --payload-content-encoding base64 \
  --payload "$(base64 -w 0 < server.crt)"

openstack secret store --name tls-key \
  --payload-content-type 'application/octet-stream' \
  --payload-content-encoding base64 \
  --payload "$(base64 -w 0 < server.key)"

# Create certificate container  
openstack secret container create --name tls-container \
  --type certificate \
  --secret certificate="$(openstack secret list --name tls-cert -f value -c 'Secret href')" \
  --secret private_key="$(openstack secret list --name tls-key -f value -c 'Secret href')"

# Get container reference for script
openstack secret container show tls-container -f value -c 'Container href'
```

## Common Customizations

### Load Balancing Algorithms
- `ROUND_ROBIN`: Equal distribution (default)
- `LEAST_CONNECTIONS`: Route to server with fewest active connections
- `SOURCE_IP`: Hash-based routing for consistent client-to-server mapping

### Session Persistence  
- `SOURCE_IP`: Client IP-based affinity (L4 example)
- `HTTP_COOKIE`: Cookie-based affinity (L7 example)
- `APP_COOKIE`: Use existing application session cookies

### Health Monitor Types
- `TCP`: Connection-based (L4 example)
- `HTTP`: HTTP GET requests with expected status codes (L7 example)
- `HTTPS`: HTTPS requests (for TLS backends)
- `PING`: ICMP ping (basic connectivity)

## Floating IP Assignment

After load balancer creation, assign a floating IP for external access:

```bash
# Create floating IP
openstack floating ip create provider

# Get load balancer VIP port
LB_ID="your-lb-id"  
VIP_PORT_ID=$(openstack loadbalancer show $LB_ID -f value -c vip_port_id)

# Associate floating IP with VIP port
FLOATING_IP="your-floating-ip"
openstack floating ip set --port $VIP_PORT_ID $FLOATING_IP
```

## Monitoring and Troubleshooting

### Check Load Balancer Status
```bash
# Overall status
openstack loadbalancer show $LB_ID

# Member health
openstack loadbalancer member list $POOL_ID

# Amphora status  
openstack loadbalancer amphora list

# Detailed status tree
openstack loadbalancer status show $LB_ID
```

### Common Issues

**Load balancer stuck in PENDING_CREATE**:
- Check amphora VM creation: `openstack server list --all | grep amphora`
- Verify management network connectivity: `ping 172.16.0.1`
- Check Octavia services: `systemctl status octavia-worker`

**Members showing ERROR status**:
- Verify backend servers are listening: `telnet <member-ip> <port>`
- Check security groups allow amphora access
- Verify health check URLs return expected status codes

**Health monitor failures**:
- Test health URLs manually: `curl http://<member-ip><health-url>`
- Adjust timeout and retry values for slow backends
- Ensure expected_codes match actual backend responses

## Cleanup

Both scripts output cleanup commands at the end:

```bash
# Delete load balancer (removes all associated resources)
openstack loadbalancer delete $LB_ID

# Delete floating IP if assigned
openstack floating ip delete $FLOATING_IP
```

## Script Features

- **Robust error handling**: Checks prerequisites and waits for resources to become active
- **Comprehensive logging**: Timestamped progress messages
- **Detailed output**: Complete configuration summary with next steps  
- **Configurable timeouts**: Adjustable wait times for resource creation
- **Cleanup instructions**: Copy-paste commands for resource removal

## Integration with Infrastructure as Code

These examples are designed to be:
- **Easily adapted** for Terraform (using terraform-provider-openstack)
- **Embedded in CI/CD** pipelines for automated testing
- **Modified for production** environments with appropriate resource sizing
- **Used as templates** for more complex multi-tier architectures

## Next Steps

1. **Test basic connectivity** to verify load balancer functionality
2. **Monitor performance** under realistic load conditions  
3. **Implement SSL/TLS** best practices for production HTTPS
4. **Consider Active/Standby topology** for high-availability requirements
5. **Integrate with monitoring** systems for operational visibility