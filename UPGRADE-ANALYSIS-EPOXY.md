# OpenStack Upgrade Analysis: Caracal (2024.1) to Epoxy (2025.1)

## Executive Summary

This document analyzes the feasibility and requirements for upgrading the current OpenStack Caracal (2024.1) single-node deployment to Epoxy (2025.1).

## Current State Assessment

### Deployed Version
- **Current**: OpenStack Caracal (2024.1) on Ubuntu 24.04 LTS
- **Target**: OpenStack Epoxy (2025.1)
- **Ubuntu**: 24.04 LTS (Ubuntu 26.04 LTS now available)
- **Platform**: Single-node deployment (32GB RAM, 4 vCPUs)
- **Environment**: Laboratory/experimental setup with nuke-and-rebuild capability

### Installed Services
- Keystone (Identity)
- Glance (Image)
- Placement
- Nova (Compute)
- Neutron (Networking) - ML2/LinuxBridge + optional OVN
- Cinder (Block Storage)
- Horizon (Dashboard)
- Heat (Orchestration)
- Octavia (Load Balancing)

## Upgrade Considerations

### 1. Ubuntu Version Compatibility

**Ubuntu 26.04 LTS Opportunity**: Ubuntu 26.04 LTS is now available and likely includes OpenStack Epoxy packages.

- **Current**: Ubuntu 24.04 LTS with Caracal (2024.1)
- **Available**: Ubuntu 26.04 LTS (likely with Epoxy support)
- **Fresh OS Installation**: Eliminates Ubuntu upgrade complications

**Recommendation**: Fresh Ubuntu 26.04 LTS installation provides clean Epoxy deployment path.

### 2. Deployment Path Analysis

**Fresh Installation**: With existing nuke-first scripts, clean deployment is straightforward:

**Current Approach**: Complete removal → Fresh installation (already proven)
**Version Jump**: Direct to Epoxy (2025.1) - no upgrade complexity

**In-Place Upgrade Path**: If needed - Caracal (2024.1) → Dalmatian (2024.2) → Epoxy (2025.1)
**NOT Recommended**: Direct Caracal → Epoxy upgrade (skipping Dalmatian)

### 3. Database Schema Migrations

Each OpenStack release includes database schema changes:
- **Keystone**: Authentication and federation updates
- **Nova**: Compute API and placement integration changes
- **Neutron**: Network topology and OVN improvements
- **Cinder**: Storage backend enhancements
- **Horizon**: Dashboard UI and API compatibility updates

### 4. Configuration Format Changes

Between releases, configuration file formats may change:
- Deprecated options removed
- New required parameters added
- Service integration patterns updated

### 5. Dependency Updates

- **Python version**: Potential upgrade requirements
- **Database**: MariaDB/MySQL version compatibility
- **Message Queue**: RabbitMQ version support
- **OVN**: Open Virtual Network version compatibility

## Risk Assessment

### High Risk Factors (In-Place Upgrade Only)
1. **Skipping intermediate release** (Dalmatian) in upgrade scenario
2. **Database corruption** during schema migrations

### Medium Risk Factors
1. **Script updates**: Installation scripts may need package name/version changes
2. **Configuration changes**: Service config format evolution
3. **Service dependencies**: New package requirements

### Low Risk Factors
1. **Laboratory environment**: Downtime acceptable, data loss tolerable
2. **Nuke-first scripts**: Clean installation eliminates upgrade complexity
3. **Ubuntu 26.04 LTS**: Fresh OS provides clean package environment
4. **Single node**: Simple architecture reduces variables
5. **Air-gap methodology**: Controlled package environment

## Implementation Options

### Option 1: Fresh Installation (RECOMMENDED)
**Approach**: Complete OS and OpenStack refresh

**Steps**:
1. Fresh Ubuntu 26.04 LTS installation
2. Verify OpenStack Epoxy package availability
3. Update installation scripts for Epoxy packages/versions
4. Run `00-download.sh` to cache Epoxy packages
5. Execute full installation sequence (01-12)

**Pros**:
- Clean slate eliminates all upgrade complexity
- Latest Ubuntu LTS with current packages
- Leverages existing nuke-first methodology
- Fastest path to Epoxy deployment
- Most predictable outcome

**Cons**:
- Complete rebuild (but scripted, so minimal effort)
- Need to update scripts for new package versions

### Option 2: Ubuntu Upgrade + Script Updates
**Approach**: Upgrade Ubuntu first, then deploy Epoxy

**Steps**:
1. Upgrade Ubuntu 24.04 → 26.04 LTS
2. Update package repositories
3. Modify scripts for Epoxy packages
4. Run nuke-and-rebuild with new packages

**Pros**:
- Preserves host configuration
- Tests Ubuntu upgrade path
- Still uses nuke-first for OpenStack

**Cons**:
- Ubuntu upgrade introduces variables
- More complex than fresh installation

### Option 3: Package Verification First
**Approach**: Minimal research phase

**Steps**:
1. Boot Ubuntu 26.04 LTS in VM/container
2. Check `apt search openstack` for Epoxy availability
3. Compare package names with current scripts
4. Proceed with Option 1 or 2 based on findings

**Pros**:
- Low-risk information gathering
- Informs implementation choice
- Minimal time investment

**Cons**:
- Delays deployment
- May reveal package unavailability

## Implementation Options

### Fresh Installation Scripts (Recommended)

Create new script set targeting Epoxy:

```
scripts-epoxy/
├── 00-download-epoxy.sh      # Updated package lists for Epoxy
├── 01-base-epoxy.sh          # Updated base service versions
├── 02-keystone-epoxy.sh      # Keystone Epoxy configuration
├── ...                       # All services updated
└── 12-ovn-migration-epoxy.sh # OVN compatibility updates
```

### Single Upgrade Script (High Risk)

Create `13-upgrade-to-epoxy.sh`:
- Service-by-service upgrade process
- Database migration handling
- Configuration updates
- Rollback capability

## Package Analysis Required

Before proceeding, we need to verify:

1. **Ubuntu 24.04 Epoxy availability**:
```bash
apt-cache policy keystone | grep -i epoxy
```

2. **Python dependencies**:
```bash
pip3 list | grep openstack
```

3. **Database compatibility**:
```bash
mysql --version
```

4. **Service version matrix**:
   - Which services have breaking changes?
   - What new dependencies are required?
   - Are there removed features we depend on?

## Questions to Resolve

### Critical Questions:
1. Is OpenStack Epoxy available in Ubuntu 24.04 LTS repositories?
2. What is the official upgrade path from Caracal to Epoxy?
3. Are there breaking API changes that affect our current setup?
4. Does OVN in Epoxy maintain compatibility with our networking setup?

### Technical Questions:
1. Do our current Cinder LVM configurations work with Epoxy?
2. Are Octavia amphora images compatible across versions?
3. Will existing Heat templates validate in Epoxy?
4. Does Horizon maintain the same dashboard structure?

## Next Steps

### Phase 1: Research and Validation
1. ✅ **Create this analysis document**
2. ⏳ **Verify Epoxy availability on Ubuntu 24.04**
3. ⏳ **Check official OpenStack upgrade documentation**
4. ⏳ **Identify breaking changes between Caracal and Epoxy**

### Phase 2: Decision Point
Based on Phase 1 findings:
- **If clean upgrade path exists**: Proceed with script updates
- **If complex/risky**: Recommend fresh installation approach
- **If unavailable**: Wait for Ubuntu packaging or consider newer Ubuntu version

### Phase 3: Implementation
- Create updated scripts based on chosen approach
- Update air-gap download mechanisms
- Test in isolated environment
- Update documentation

## Recommendation

**Primary Recommendation**: Option 1 (Fresh Installation)

Given the laboratory environment, existing nuke-first scripts, and Ubuntu 26.04 LTS availability, the most efficient path is a complete fresh installation:

1. **Fresh Ubuntu 26.04 LTS installation** - Clean OS with latest packages
2. **Verify Epoxy package availability** - Quick `apt search openstack` check
3. **Update installation scripts** - Minimal changes for new package versions
4. **Full deployment** - Leverage existing automated installation

**Why This Approach**:
- **Laboratory environment**: Downtime and data loss acceptable
- **Nuke-first methodology**: Scripts already designed for clean installation
- **Ubuntu 26.04 available**: Fresh OS likely includes Epoxy packages
- **Minimal script changes**: Package names typically remain consistent
- **Fastest deployment**: Skip all upgrade complexity

### Estimated Effort
- **OS Installation**: 30 minutes
- **Package verification**: 15 minutes
- **Script updates**: 1-2 hours (package versions, dependency changes)
- **Full deployment**: 2-3 hours (existing automation)
- **Testing/validation**: 1 hour

**Total**: ~6 hours for complete Epoxy deployment

## Conclusion

With Ubuntu 26.04 LTS available and existing nuke-first scripts, upgrading to OpenStack Epoxy (2025.1) is a straightforward fresh installation rather than a complex upgrade scenario. The laboratory environment eliminates data preservation concerns, making this the optimal path forward.

---

> [!NOTE]  
> Document updated: 2024-04-10  
> Status: Fresh installation approach recommended - Ubuntu 26.04 LTS + script updates