# OpenStack Single-Node Deployment

Air-gapped, repeatable OpenStack Caracal (2024.1) installation on Ubuntu 24.04 — designed for a single laptop (32 GB RAM, 4 vCPU).

## Quick Start

```bash
# Phase 1: Download everything (requires internet)
sudo bash scripts/00-download.sh

# Phase 2: Install (works offline)
sudo bash scripts/01-base.sh
sudo bash scripts/02-keystone.sh
sudo bash scripts/03-glance.sh
sudo bash scripts/04-placement.sh
sudo bash scripts/05-nova.sh
sudo bash scripts/06-neutron.sh
sudo bash scripts/07-cinder.sh
sudo bash scripts/08-horizon.sh
sudo bash scripts/09-heat.sh
sudo bash scripts/10-post-install.sh
sudo bash scripts/11-octavia.sh

# Phase 3: Optional Mistral AI Integration
sudo bash scripts/13-mistral-ai-core.sh
sudo bash scripts/14-mistral-ai-compute.sh
sudo bash scripts/15-mistral-ai-network.sh
sudo bash scripts/16-mistral-ai-loadbalancer.sh
sudo bash scripts/17-mistral-ai-quota.sh
sudo bash scripts/18-mistral-ai-agent.sh
sudo bash scripts/19-mistral-ai-horizon.sh

# Phase 4: Optional OVN Migration (LinuxBridge → OVN)
sudo bash scripts/12-ovn-migration.sh --validate-only  # Pre-migration check
sudo bash scripts/12-ovn-migration.sh                 # Migrate to OVN

# Uninstall everything
sudo bash scripts/99-uninstall.sh
```

## Current State

| Script | Service | Status |
|---|---|---|
| 00-download.sh | Air-gap cache | Ready |
| 01-base.sh | MariaDB, RabbitMQ, Memcached | Ready |
| 02-keystone.sh | Identity (Keystone) | Ready |
| 03-glance.sh | Image (Glance) | Ready |
| 04-placement.sh | Placement | Ready |
| 05-nova.sh | Compute (Nova) | Ready |
| 06-neutron.sh | Networking (Neutron LinuxBridge) | Ready |
| 07-cinder.sh | Block Storage (Cinder) | Ready |
| 08-horizon.sh | Dashboard (Horizon) | Ready |
| 09-heat.sh | Orchestration (Heat) | Ready |
| 10-post-install.sh | Networks, flavors, verification | Ready |
| 11-octavia.sh | Load Balancing (Octavia) | Ready |
| 12-ovn-migration.sh | OVN Migration (LinuxBridge → OVN) | Ready |
| 13-mistral-ai-core.sh | AI Core Framework | Ready |
| 14-mistral-ai-compute.sh | AI Compute Tools | Ready |
| 15-mistral-ai-network.sh | AI Network Tools | Ready |
| 16-mistral-ai-loadbalancer.sh | AI Load Balancer Tools | Ready |
| 17-mistral-ai-quota.sh | AI Quota & Cost Tools | Ready |
| 18-mistral-ai-agent.sh | AI Agent & CLI | Ready |
| 19-mistral-ai-horizon.sh | AI Dashboard Integration | Ready |
| 99-uninstall.sh | Complete removal | Ready |

## Documentation

| Document | Description |
|---|---|
| [OPERATIONS.md](OPERATIONS.md) | Complete installation and operations guide (architecture, troubleshooting, daily operations) |
| [CINDER-TROUBLESHOOTING.md](CINDER-TROUBLESHOOTING.md) | Cinder block storage troubleshooting and issue resolution |
| [OCTAVIA-TROUBLESHOOTING.md](OCTAVIA-TROUBLESHOOTING.md) | Octavia load balancer troubleshooting and issue resolution |
| [ovn-migration-guide.md](ovn-migration-guide.md) | OVN migration architecture and implementation guide |
| [OVN-MIGRATION-TROUBLESHOOTING.md](OVN-MIGRATION-TROUBLESHOOTING.md) | OVN migration troubleshooting and issue resolution |
| [examples/](examples/) | Load balancer configuration examples and templates |

## Access

- Dashboard: http://127.0.0.1/horizon/
- Admin: `admin` / `changeit`
- Demo: `demo` / `changeit`

## OVN Migration

The deployment initially uses **ML2/LinuxBridge** for networking. After the base installation, you can optionally migrate to **ML2/OVN** for improved performance and features:

### Benefits of OVN:
- **Distributed routing** — L3 processing on compute nodes
- **Better performance** — OVN ACLs instead of iptables for security groups
- **Fewer agents** — ~5 agents per node → 2 agents per node
- **Advanced features** — Built-in load balancing, better IPv6 support
- **Better debugging** — `ovn-trace` for packet path analysis

### Migration Process:
1. **Validate**: `sudo bash scripts/12-ovn-migration.sh --validate-only`
2. **Migrate**: `sudo bash scripts/12-ovn-migration.sh`
3. **Verify**: Check network agents show only OVN controller

The migration is **reversible** (with backups) and preserves all existing networks and instances.
## Mistral AI Integration

The deployment includes **optional** AI-powered OpenStack automation using Mistral AI for natural language infrastructure management:

### AI Capabilities:
- **Natural Language Operations** — Create resources using plain English requests
- **Immediate Execution** — AI directly executes OpenStack operations via tools rather than providing instructions
- **Comprehensive Tool Set** — Compute (Nova), networking (Neutron), load balancing (Octavia), quota management
- **Transaction Rollback** — Built-in safety with operation rollback capabilities
- **Web Dashboard** — Integrated chat interface within Horizon dashboard
- **Action-Oriented** — AI prioritizes tool execution for create/launch/deploy requests over providing manual steps

### AI Installation Process:
1. **Core**: `sudo bash scripts/13-mistral-ai-core.sh` — Base framework and dependencies
2. **Tools**: Install scripts 14-17 for specific OpenStack service integrations
3. **Agent**: `sudo bash scripts/18-mistral-ai-agent.sh` — Main AI agent with CLI access
4. **Dashboard**: `sudo bash scripts/19-mistral-ai-horizon.sh` — Web interface integration

### Usage Examples:
- "Create a load balancer called web-lb for port 80"
- "Launch 3 instances using m1.small on the private network"
- "Check if I have quota for 5 more servers"
- "Delete all instances with 'test' in the name"

The AI automatically detects action-oriented requests and executes the appropriate OpenStack tools immediately instead of providing step-by-step instructions.
