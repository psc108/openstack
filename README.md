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
| 06-neutron.sh | Networking (Neutron) | Ready |
| 07-cinder.sh | Block Storage (Cinder) | Ready |
| 08-horizon.sh | Dashboard (Horizon) | Ready |
| 09-heat.sh | Orchestration (Heat) | Ready |
| 10-post-install.sh | Networks, flavors, verification | Ready |
| 11-octavia.sh | Load Balancing (Octavia) | Ready |
| 99-uninstall.sh | Complete removal | Ready |

## Documentation

| Document | Description |
|---|---|
| [OPERATIONS.md](OPERATIONS.md) | Complete installation and operations guide (architecture, troubleshooting, daily operations) |

## Access

- Dashboard: http://127.0.0.1/horizon/
- Admin: `admin` / `changeit`
- Demo: `demo` / `changeit`
