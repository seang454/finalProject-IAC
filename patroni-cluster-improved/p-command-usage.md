# Patroni HA Cluster — Command Reference

## Your Cluster Details

| Node | Public IP | Internal IP |
|------|-----------|-------------|
| pg-node1 | 34.86.199.201 | 10.150.0.11 |
| pg-node2 | 34.12.95.102 | 10.164.0.8 |
| pg-node3 | 34.89.57.142 | 10.154.0.18 |
| ha-proxy1 | 34.13.12.181 | 10.154.0.15 |
| ha-proxy2 | 35.189.117.58 | 10.154.0.16 |
| ha-proxy3 | 34.105.205.168 | 10.154.0.17 |

---

## Category 1 — Cluster Status

Commands to check what is happening in the cluster right now.

```bash
# Show all members, their roles, state, and replication lag
# Run from any pg-node
sudo patronictl -c /etc/patroni/patroni.yml list
```
> Shows a table with Leader/Replica roles, running/stopped state, and lag in MB.
> Lag should always be 0 for healthy replicas.

```bash
# Show the current cluster configuration stored in etcd
sudo patronictl -c /etc/patroni/patroni.yml show-config
```
> Shows all PostgreSQL parameters managed by Patroni — max_connections,
> shared_buffers, archive_mode, etc. This is the source of truth for config.

```bash
# Show history of all leader changes (failovers and switchovers)
sudo patronictl -c /etc/patroni/patroni.yml history
```
> Each line shows: timeline, LSN position, reason for change, and timestamp.
> Useful to understand what happened during incidents.

```bash
# Watch cluster status in real-time — updates every 2 seconds
watch -n 2 'sudo patronictl -c /etc/patroni/patroni.yml list'
```
> Leave this running in a second terminal during failover tests.

---

## Category 2 — Patroni REST API

HTTP endpoints exposed by Patroni on port 8008. Use these for health checks,
monitoring tools, and HAProxy backend checks.

```bash
# Full node information — role, state, timeline, replication info
curl -s http://10.150.0.11:8008/patroni | jq

# Returns 200 only if this node is the current leader
curl -s -o /dev/null -w "%{http_code}" http://10.150.0.11:8008/leader

# Returns 200 only if this node is a replica
curl -s -o /dev/null -w "%{http_code}" http://10.150.0.11:8008/replica

# Returns 200 if this node is healthy (leader OR replica)
curl -s -o /dev/null -w "%{http_code}" http://10.150.0.11:8008/health

# Returns 200 only if this node is the primary (same as /leader)
curl -s -o /dev/null -w "%{http_code}" http://10.150.0.11:8008/primary

# Full cluster info — all members, their roles and lag
curl -s http://10.150.0.11:8008/cluster | jq

# History of all leader elections
curl -s http://10.150.0.11:8008/history | jq

# Current cluster configuration
curl -s http://10.150.0.11:8008/config | jq
```

> HAProxy uses `/primary` and `/replica` endpoints to decide which backend
> to route traffic to. Only the current leader returns 200 for `/primary`.

---

## Category 3 — Failover and Switchover

Commands to move the leader between nodes.

```bash
# AUTOMATIC FAILOVER — simulate a crash by stopping Patroni on the leader
# Run on the current leader (e.g. pg-node1)
sudo systemctl stop patroni
```
> Within 30 seconds Patroni elects a new leader automatically.
> The old leader rejoins as a replica when you start it again.

```bash
# MANUAL SWITCHOVER — move leader to a specific node gracefully (no downtime)
# Interactive mode — prompts you to pick the candidate
sudo patronictl -c /etc/patroni/patroni.yml switchover

# Non-interactive mode — specify leader and candidate directly
sudo patronictl -c /etc/patroni/patroni.yml switchover \
  --leader pg-node1 --candidate pg-node2 --force
```
> Use switchover for planned maintenance — e.g. before rebooting the leader.
> The difference from failover: switchover is graceful, failover is emergency.

```bash
# FORCE FAILOVER — emergency only, forces a failover even if leader is alive
sudo patronictl -c /etc/patroni/patroni.yml failover \
  --master pg-node1 --candidate pg-node2 --force
```
> Use this only when the leader is unresponsive and switchover is not possible.

---

## Category 4 — Node Management

Commands to manage individual nodes.

```bash
# Restart PostgreSQL on a specific node (without triggering failover)
sudo patronictl -c /etc/patroni/patroni.yml restart postgres-cluster pg-node2
```
> Patroni restarts PostgreSQL safely. If the node is the leader, it waits
> for replicas to catch up before restarting to avoid data loss.

```bash
# Rolling restart — restarts all nodes one by one (replicas first, then leader)
sudo patronictl -c /etc/patroni/patroni.yml restart postgres-cluster
```
> Use this after config changes that require a restart (e.g. archive_mode).

```bash
# Reload config without restart — for parameters that don't need restart
sudo patronictl -c /etc/patroni/patroni.yml reload postgres-cluster pg-node1
```
> Works for parameters like work_mem, log_min_duration_statement, etc.
> Does NOT work for archive_mode — that requires a restart.

```bash
# Reinitialise a broken replica — wipes data and reclones from leader
sudo patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster pg-node3
```
> Use when a replica is stuck in "stopped" or has fallen too far behind.
> This deletes ALL data on that node and streams a fresh copy from the leader.

```bash
# Pause Patroni automatic failover (maintenance mode)
sudo patronictl -c /etc/patroni/patroni.yml pause
```
> Patroni stops managing the cluster. Useful during maintenance to prevent
> unexpected failovers. PostgreSQL keeps running normally.

```bash
# Resume Patroni automatic failover
sudo patronictl -c /etc/patroni/patroni.yml resume
```

---

## Category 5 — Configuration Management

Commands to change cluster configuration.

```bash
# Edit cluster configuration stored in etcd
# Opens a text editor — changes apply to ALL nodes automatically
sudo patronictl -c /etc/patroni/patroni.yml edit-config
```
> This is how you change PostgreSQL parameters like archive_mode, work_mem,
> max_connections. Patroni syncs the change to all nodes via etcd.
> Some parameters require a restart — Patroni will tell you.

```bash
# Apply a config change from a file
sudo patronictl -c /etc/patroni/patroni.yml edit-config --apply myconfig.yaml
```

---

## Category 6 — etcd Commands

Commands to check the distributed configuration store.

```bash
# Check all 3 etcd members are in the cluster
etcdctl cluster-health
```
> Must show "cluster is healthy" with all 3 members.
> If only 1 member shows, the cluster is broken — wipe data dirs and reinit.

```bash
# List all etcd members with their peer and client URLs
etcdctl member list
```
> Check that peer URLs use internal IPs (10.x.x.x), not localhost.
> If you see localhost:2380, the data dir was stale — wipe and restart.

```bash
# View Patroni's data stored in etcd
etcdctl get /db/postgres-cluster --prefix
```
> Shows the leader lock, member registrations, and cluster config.
> Useful for debugging when Patroni behaves unexpectedly.

---

## Category 7 — PostgreSQL Direct Commands

Commands to run SQL queries directly on PostgreSQL.

```bash
# Connect as superuser on the primary through HAProxy
psql -h 34.13.12.181 -p 5000 -U postgres -d postgres

# Connect to replicas through HAProxy (read-only)
psql -h 34.13.12.181 -p 5001 -U postgres -d postgres

# Connect directly to a specific node
psql -h 10.150.0.11 -p 5432 -U postgres -d postgres
```

```sql
-- Check which node you are connected to and whether it is the primary
SELECT inet_server_addr() AS connected_to, pg_is_in_recovery() AS is_replica;

-- Check replication status on the primary — shows all connected replicas
SELECT client_addr, state, sent_lsn, replay_lsn,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag
FROM pg_stat_replication;

-- Check WAL archiving is working
SELECT * FROM pg_stat_archiver;

-- Check replication slots
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;

-- Check recovery status on a replica
SELECT pg_is_in_recovery() AS is_replica,
       pg_last_wal_receive_lsn() AS received,
       pg_last_wal_replay_lsn() AS replayed,
       pg_last_xact_replay_timestamp() AS last_replay_time;

-- Force a WAL switch (triggers archiving immediately)
SELECT pg_switch_wal();

-- Check archive_mode is enabled
SHOW archive_mode;

-- Check archive_command
SHOW archive_command;
```

---

## Category 8 — Backup Commands (pgBackRest)

Commands to manage backups. Run as postgres user on the current leader.

```bash
# Take a full backup — backs up the entire database
sudo -u postgres pgbackrest --stanza=postgres-cluster --type=full backup

# Take a differential backup — only backs up changes since last full backup
sudo -u postgres pgbackrest --stanza=postgres-cluster --type=diff backup

# Take an incremental backup — only backs up changes since last any backup
sudo -u postgres pgbackrest --stanza=postgres-cluster --type=incr backup

# Show all backups — size, timestamp, WAL range
sudo -u postgres pgbackrest --stanza=postgres-cluster info

# Verify backup integrity — checks all files are intact and restorable
sudo -u postgres pgbackrest --stanza=postgres-cluster check

# Use the backup script (checks if leader first)
sudo -u postgres patroni-backup.sh full
sudo -u postgres patroni-backup.sh diff

# View backup log
tail -f /var/log/pgbackrest/backup.log

# View pgBackRest main log
tail -f /var/log/pgbackrest/pgbackrest.log
```

### Restore commands (disaster recovery)

```bash
# Stop Patroni on ALL nodes before restoring
sudo systemctl stop patroni   # run on all 3 nodes

# Restore latest backup
sudo -u postgres pgbackrest --stanza=postgres-cluster restore

# Restore to a specific point in time (PITR)
sudo -u postgres pgbackrest --stanza=postgres-cluster \
  --type=time "--target=2026-03-19 16:00:00" restore

# Dry run — verify restore is possible without touching live data
sudo -u postgres pgbackrest --stanza=postgres-cluster restore --dry-run
```

---

## Category 9 — Service Management

Commands to start, stop, and check system services.

```bash
# Patroni service
sudo systemctl start patroni
sudo systemctl stop patroni
sudo systemctl restart patroni
sudo systemctl status patroni

# etcd service
sudo systemctl start etcd
sudo systemctl stop etcd
sudo systemctl restart etcd
sudo systemctl status etcd

# HAProxy service (on ha-proxy nodes)
sudo systemctl start haproxy
sudo systemctl stop haproxy
sudo systemctl restart haproxy
sudo systemctl status haproxy

# Keepalived service (on ha-proxy nodes)
sudo systemctl start keepalived
sudo systemctl stop keepalived
sudo systemctl restart keepalived
sudo systemctl status keepalived
```

---

## Category 10 — Log Commands

Commands to view logs for debugging.

```bash
# Patroni logs — real-time
sudo journalctl -u patroni -f

# Patroni logs — last 50 lines
sudo journalctl -u patroni -n 50 --no-pager

# etcd logs — real-time
sudo journalctl -u etcd -f

# PostgreSQL logs
sudo tail -f /var/log/postgresql/postgresql-$(date +%Y-%m-%d).log

# HAProxy logs
sudo journalctl -u haproxy -f

# Keepalived logs
sudo journalctl -u keepalived -f

# pgBackRest backup log
tail -f /var/log/pgbackrest/backup.log
```

---

## Category 11 — Connectivity Checks

Commands to verify network connectivity between nodes.

```bash
# Test etcd port (2379) is reachable between nodes
nc -zv 10.150.0.11 2379   # pg-node1 etcd
nc -zv 10.164.0.8  2379   # pg-node2 etcd
nc -zv 10.154.0.18 2379   # pg-node3 etcd

# Test Patroni REST API port (8008)
nc -zv 10.150.0.11 8008
nc -zv 10.164.0.8  8008
nc -zv 10.154.0.18 8008

# Test PostgreSQL port (5432)
nc -zv 10.150.0.11 5432
nc -zv 10.164.0.8  5432
nc -zv 10.154.0.18 5432

# Check PostgreSQL is ready to accept connections
sudo -u postgres pg_isready -h localhost -p 5432

# Check which ports are listening on this node
sudo ss -tlnp | grep -E "5432|8008|2379|2380"
```

---

## Category 12 — Troubleshooting

Commands to diagnose and fix common problems.

```bash
# Check disk space on data directory
df -h /var/lib/patroni

# Check PostgreSQL data directory size
du -sh /var/lib/patroni/data

# Check system resources
htop
free -h

# Check all Patroni processes
ps aux | grep patroni

# Check open file limits
ulimit -n

# Fix permission issues (if Patroni fails to start)
sudo chown -R postgres:postgres /var/lib/patroni
sudo chown -R postgres:postgres /etc/patroni
sudo chmod 600 /etc/patroni/patroni.yml

# Wipe stale etcd data and restart (fixes single-node cluster bug)
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd/default
sudo systemctl start etcd

# Wipe stale Patroni data and restart (fixes uninitialized replica)
sudo systemctl stop patroni
sudo rm -rf /var/lib/patroni/data
sudo systemctl start patroni
```

---

## Quick Reference — Most Used Commands

| What you want to do | Command |
|---------------------|---------|
| Check cluster health | `sudo patronictl -c /etc/patroni/patroni.yml list` |
| Watch live status | `watch -n 2 'sudo patronictl -c /etc/patroni/patroni.yml list'` |
| Move leader to another node | `sudo patronictl -c /etc/patroni/patroni.yml switchover` |
| Simulate a crash | `sudo systemctl stop patroni` |
| Fix broken replica | `sudo patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster <node>` |
| Change PostgreSQL config | `sudo patronictl -c /etc/patroni/patroni.yml edit-config` |
| Take a full backup | `sudo -u postgres pgbackrest --stanza=postgres-cluster --type=full backup` |
| Check backups | `sudo -u postgres pgbackrest --stanza=postgres-cluster info` |
| Check etcd health | `etcdctl cluster-health` |
| View Patroni logs | `sudo journalctl -u patroni -f` |
| Connect to primary via HAProxy | `psql -h 34.13.12.181 -p 5000 -U postgres -d postgres` |
| Connect to replica via HAProxy | `psql -h 34.13.12.181 -p 5001 -U postgres -d postgres` |