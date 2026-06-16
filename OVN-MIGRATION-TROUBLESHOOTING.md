# OVN Migration Troubleshooting Guide

## Script Syntax and Generation Issues

### Escaped Newlines in Generated Script

**Symptom**: Script contains literal `\n` sequences causing syntax errors throughout the file
```bash
$ bash -n scripts/12-ovn-migration.sh
scripts/12-ovn-migration.sh: line 48: syntax error near unexpected token `$'log_message "Phase 1: Pre-migration preparation started" \n''
```

**Cause**: Code generation included escaped newlines (`\\n`) instead of actual line breaks

**Resolution**: 
1. Delete the malformed script: `rm scripts/12-ovn-migration.sh`
2. Regenerate with proper bash formatting (no escaped newlines)
3. Validate syntax: `bash -n scripts/12-ovn-migration.sh`

## Pre-Migration Validation Issues

### Missing OVN Packages

**Symptom**: Package validation fails with "Package not found" errors
```bash
E: Unable to locate package ovn-central
E: Unable to locate package ovn-host
```

**Cause**: OVN packages not included in air-gap download cache

**Resolution**: Add to `scripts/00-download.sh`:
```bash
ovn-central ovn-host ovn-common python3-ovn
```

### Neutron Service Status Check Failures

**Symptom**: Pre-migration validation shows services as failed
```bash
neutron-linuxbridge-agent.service - failed
neutron-dhcp-agent.service - failed
```

**Cause**: Services may be masked or disabled after previous troubleshooting

**Resolution**: 
```bash
sudo systemctl unmask neutron-linuxbridge-agent neutron-dhcp-agent neutron-l3-agent
sudo systemctl enable neutron-linuxbridge-agent neutron-dhcp-agent neutron-l3-agent
sudo systemctl start neutron-linuxbridge-agent neutron-dhcp-agent neutron-l3-agent
```

## Database Migration Issues

### Database Connection Failures

**Symptom**: Migration fails with database access errors
```bash
ERROR: Could not connect to database
pymysql.err.OperationalError: (2003, "Can't connect to MySQL server")
```

**Cause**: Database service stopped or credentials changed

**Resolution**: 
1. Verify database service: `sudo systemctl status mariadb`
2. Test connection: `mysql -u neutron -p neutron`
3. Check credentials in `/etc/neutron/neutron.conf`

### Network Topology Corruption

**Symptom**: Networks missing after database synchronization
```bash
$ openstack network list
# Empty result or missing networks
```

**Cause**: Database sync failed or incomplete

**Resolution**:
1. Run rollback: `sudo bash scripts/12-ovn-migration.sh --rollback`
2. Restore database from backup
3. Verify network topology before retry

## OVN Service Issues

### OVN Central Database Not Starting

**Symptom**: OVN services fail to start
```bash
sudo systemctl status ovn-central
● ovn-central.service - Open Virtual Network central components
   Active: failed (Result: exit-code)
```

**Cause**: Database initialization failed or port conflicts

**Resolution**:
```bash
# Check port availability
sudo netstat -tulpn | grep -E ':(6641|6642|6643|6644)'

# Initialize databases manually
sudo ovn-ctl start_northd
sudo ovn-ctl start_ovsdb --db-nb-create-insecure-remote=yes --db-sb-create-insecure-remote=yes
```

### OVS Bridge Configuration Conflicts

**Symptom**: Bridge creation fails with existing bridges
```bash
ovs-vsctl: cannot create a bridge named br-int because a bridge named br-int already exists
```

**Cause**: Existing LinuxBridge configuration conflicts

**Resolution**:
```bash
# Clean existing bridges carefully
sudo ovs-vsctl del-br br-int 2>/dev/null || true
sudo ovs-vsctl del-br br-tun 2>/dev/null || true
# Script handles this automatically
```

## Agent Configuration Issues

### Neutron OVN Agents Not Registering

**Symptom**: Agents don't appear in agent list
```bash
$ openstack network agent list
# Missing neutron-ovn-controller or neutron-ovn-metadata-agent
```

**Cause**: Configuration mismatch or service startup order

**Resolution**:
1. Check OVN controller config: `/etc/neutron/plugins/ml2/ml2_conf.ini`
2. Verify OVS system-id: `sudo ovs-vsctl get open . external_ids:system-id`
3. Restart in order:
```bash
sudo systemctl restart openvswitch-switch
sudo systemctl restart ovn-controller
sudo systemctl restart neutron-server
```

## Network Connectivity Issues

### Instance Network Loss During Migration

**Symptom**: Running instances lose network connectivity
```bash
# From instance console - no network connectivity
ping 8.8.8.8 # timeout
```

**Cause**: Network topology change during migration

**Resolution**:
1. Immediate: Run rollback procedure
2. For planned migration: Schedule maintenance window
3. Post-migration: Verify security groups and routing

### Provider Network Mapping Issues

**Symptom**: External network connectivity lost
```bash
$ openstack floating ip create external
ERROR: Network external not found
```

**Cause**: Provider network bridge mapping incorrect

**Resolution**: Update `/etc/neutron/plugins/ml2/ml2_conf.ini`:
```ini
[ovn]
ovn_nb_connection = tcp:127.0.0.1:6641
ovn_sb_connection = tcp:127.0.0.1:6642
bridge_mappings = provider:br-ex
```

## Security Group Performance

### Security Group Rules Not Applied

**Symptom**: Security group changes not taking effect
```bash
$ openstack security group rule create --protocol tcp --dst-port 80 default
# Rule created but traffic still blocked
```

**Cause**: OVN ACL sync issues

**Resolution**:
```bash
# Force security group sync
sudo systemctl restart neutron-server
# Check OVN ACLs
sudo ovn-nbctl list acl
```

## Dashboard Integration Issues

### Neutron Panels Not Working After Migration

**Symptom**: Horizon networks/routers panels show errors or outdated information
```bash
# Dashboard shows "Error retrieving networks" or stale LinuxBridge data
```

**Cause**: Horizon dashboard cache not cleared after backend migration

**Resolution**:
```bash
# Clear Python bytecode cache
sudo find /usr/lib/python3/dist-packages/openstack_dashboard/ -name "*.pyc" -delete
sudo find /usr/lib/python3/dist-packages/openstack_dashboard/ -name "__pycache__" -type d -exec rm -rf {} +

# Update static files
cd /usr/share/openstack-dashboard
sudo python3 manage.py collectstatic --noinput
sudo python3 manage.py compress --force

# Restart Apache
sudo systemctl restart apache2
```

### Dashboard Shows LinuxBridge-Specific Options

**Symptom**: Horizon still shows HA router options or LinuxBridge-specific features
```bash
# Router creation dialog shows "High Availability" option (not applicable to OVN)
```

**Cause**: Dashboard configuration not updated for OVN backend capabilities

**Resolution**: Migration script now creates `/usr/share/openstack-dashboard/openstack_dashboard/local/local_settings.d/_50_neutron.py` with OVN-specific settings.

### Performance Issues in Network Panels

**Symptom**: Dashboard slow to load network topology or router information
```bash
# Network topology takes long to render or times out
```

**Cause**: Dashboard querying inefficient OVN database calls

**Resolution**:
```bash
# Monitor database query patterns
sudo ovn-nbctl --timeout=5 show
sudo ovn-sbctl --timeout=5 show

# If timeouts occur, check OVN service health
sudo systemctl status ovn-central ovn-controller
```

## Migration Rollback Issues

### Incomplete Rollback State

**Symptom**: System in mixed state after rollback
```bash
$ sudo systemctl status neutron-ovn-*
# Some OVN services still running
$ sudo systemctl status neutron-linuxbridge-*
# Some LinuxBridge services not started
```

**Cause**: Rollback script didn't complete all steps

**Resolution**:
1. Manual cleanup:
```bash
sudo systemctl stop neutron-ovn-controller neutron-ovn-metadata-agent
sudo systemctl disable neutron-ovn-controller neutron-ovn-metadata-agent
sudo systemctl enable neutron-linuxbridge-agent neutron-dhcp-agent neutron-l3-agent
sudo systemctl start neutron-linuxbridge-agent neutron-dhcp-agent neutron-l3-agent
```
2. Restore configuration backup manually

### Database Restore Failures

**Symptom**: Database backup restore fails
```bash
ERROR 1062 (23000): Duplicate entry for key 'PRIMARY'
```

**Cause**: Database not properly cleaned before restore

**Resolution**:
```bash
# Drop and recreate database
mysql -u root -p -e "DROP DATABASE neutron; CREATE DATABASE neutron;"
mysql -u root -p -e "GRANT ALL ON neutron.* TO 'neutron'@'localhost';"
mysql -u neutron -p neutron < /tmp/neutron-backup-*.sql
```

## Performance and Monitoring

### High CPU Usage During Migration

**Symptom**: System becomes unresponsive during migration
```bash
top # Shows high CPU usage from neutron processes
```

**Cause**: Large network topology causing intensive processing

**Resolution**:
1. Run migration during low-usage hours
2. Increase system resources if possible
3. Monitor with: `watch "ps aux | grep neutron"`

### Migration Timeout Issues

**Symptom**: Migration script times out
```bash
Timeout waiting for OVN services to start
```

**Cause**: System under heavy load or resource constraints

**Resolution**:
1. Increase timeout values in script
2. Check system resources: `free -h`, `df -h`
3. Run migration in screen session: `screen -S ovn-migration`

## Validation and Verification

### Network Functionality Test Failures

**Symptom**: Post-migration tests fail
```bash
$ ping 192.168.100.10
PING 192.168.100.10: Network is unreachable
```

**Cause**: Routing tables not updated after migration

**Resolution**:
1. Verify provider network configuration
2. Check routing: `ip route show`
3. Restart network services: `sudo systemctl restart networking`

### Dashboard Integration Issues

**Symptom**: Horizon shows network errors after migration
```bash
# Dashboard shows "Error retrieving networks"
```

**Cause**: API service configuration mismatch

**Resolution**:
1. Clear Horizon cache: `sudo service apache2 restart`
2. Check neutron API: `curl http://127.0.0.1:9696/v2.0/networks`
3. Verify Keystone endpoints

## Known Issues and Limitations

| Issue | Impact | Workaround | Status |
|---|---|---|---|
| IPv6 networks not migrated | IPv6 connectivity lost | Manual recreation required | Open |
| LBaaS migration incomplete | Load balancer downtime | Recreate load balancers | Open |
| Large topology timeout | Migration fails on big deployments | Split into smaller chunks | Open |
| Memory pressure during sync | System instability | Add swap space temporarily | Open |
| Horizon cache stale after migration | Dashboard shows incorrect network info | Clear Python cache and restart Apache | Fixed in script |

## Emergency Procedures

### Complete Migration Failure Recovery

If migration completely fails and rollback doesn't work:

1. **Immediate stabilization**:
```bash
sudo systemctl stop neutron-server neutron-ovn-* neutron-linuxbridge-*
sudo systemctl stop openvswitch-switch ovn-*
```

2. **Restore from backup**:
```bash
# Restore configuration
sudo cp -r /tmp/migration-backup/etc/* /etc/
# Restore database
mysql -u neutron -p neutron < /tmp/neutron-backup-*.sql
```

3. **Restart original services**:
```bash
sudo systemctl start neutron-server
sudo systemctl start neutron-linuxbridge-agent neutron-dhcp-agent neutron-l3-agent
```

### Contact Information

For critical issues during migration:
- OpenStack logs: `/var/log/neutron/`
- OVN logs: `/var/log/openvswitch/`
- Migration logs: `/var/log/ovn-migration.log`

---

> [!NOTE]  
> Document version 1.0 — Updated 2024-04-10  
> Based on OpenStack Caracal (2024.1) with OVN 23.06