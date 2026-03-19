# HA PostgreSQL Cluster on GCP — Full Project Documentation

> Automated, highly available PostgreSQL cluster deployed on Google Cloud Platform using Ansible.  
> Covers infrastructure provisioning, cluster management, and database connectivity.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture](#2-architecture)
3. [Repository Structure](#3-repository-structure)
4. [Prerequisites](#4-prerequisites)
5. [Configuration Reference](#5-configuration-reference)
6. [Deployment Guide](#6-deployment-guide)
7. [Connecting to the Database](#7-connecting-to-the-database)
8. [Cluster Operations](#8-cluster-operations)
9. [Monitoring](#9-monitoring)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Project Overview

This project automates the full lifecycle of a production-grade PostgreSQL cluster on GCP:

| Layer | Tool | Purpose |
|---|---|---|
| Infrastructure | `gcp_instances` Ansible role | Provision GCP VMs, reserve static IPs, generate inventory |
| HA Manager | Patroni | Leader election, automatic failover, replica management |
| Consensus Store | etcd (3-node) | Distributed lock for leader election |
| Load Balancer | HAProxy | Single connection endpoint, routes writes/reads automatically |
| Database | PostgreSQL 16 | Actual data storage |

**What happens automatically:**

- If the primary PostgreSQL node dies → Patroni detects it within `ttl` seconds (default 30 s), promotes the most up-to-date replica, and reconfigures remaining replicas to follow the new primary
- If a GCP zone is exhausted or down → the provisioning role detects it pre-flight and remaps affected machines to a healthy zone in a different region
- HAProxy continuously health-checks the Patroni REST API on every node and only routes traffic to the current primary (port 5000) or healthy replicas (port 5001)

---

## 2. Architecture

```
                         ┌──────────────────────────────────┐
                         │           Your Application        │
                         └──────────┬───────────────┬────────┘
                                    │               │
                              Writes│         Reads │
                                    ▼               ▼
                         ┌──────────────────────────────────┐
                         │            HAProxy               │
                         │  :5000 primary  :5001 replicas   │
                         │  :5002 all      :7000 stats page │
                         └──────┬──────────────────┬────────┘
                                │  health checks   │
                         (GET /primary)     (GET /replica)
                                │                  │
          ┌─────────────────────┼──────────────────┼──────────────────┐
          │                     │                  │                  │
          ▼                     ▼                  ▼                  │
   ┌─────────────┐      ┌─────────────┐    ┌─────────────┐           │
   │  pg-node1   │      │  pg-node2   │    │  pg-node3   │           │
   │             │      │             │    │             │           │
   │  PostgreSQL │◄─────│  PostgreSQL │    │  PostgreSQL │           │
   │  (Primary)  │  WAL │  (Replica)  │    │  (Replica)  │           │
   │             │stream│             │    │             │           │
   │  Patroni    │      │  Patroni    │    │  Patroni    │           │
   │  :8008 API  │      │  :8008 API  │    │  :8008 API  │           │
   │             │      │             │    │             │           │
   │  etcd       │◄────►│  etcd       │◄──►│  etcd       │           │
   │  :2379/2380 │      │  :2379/2380 │    │  :2379/2380 │           │
   └─────────────┘      └─────────────┘    └─────────────┘           │
    asia-east1-b          asia-east1-a       asia-east1-c             │
                                                                      │
   ┌──────────────────────────────────────────────────────────────────┘
   │  GCP Zones span different regions for zone-level fault tolerance
   └─ Zone exhaustion → role auto-remaps to a different region
```

### Port Reference

| Port | Node | Service | Description |
|------|------|---------|-------------|
| 5432 | Each DB node | PostgreSQL | Direct database access (per node) |
| 8008 | Each DB node | Patroni REST API | Health checks, cluster info |
| 2379 | Each DB node | etcd client | Client connections |
| 2380 | Each DB node | etcd peer | Inter-node etcd traffic |
| 5000 | HAProxy | Primary endpoint | Read-write, always routes to leader |
| 5001 | HAProxy | Replica endpoint | Read-only, round-robin across replicas |
| 5002 | HAProxy | All-nodes endpoint | Read traffic including the leader |
| 7000 | HAProxy | Stats dashboard | Web UI showing backend health |

---

## 3. Repository Structure

```
project-root/
│
├── site.yml                        # Top-level playbook — runs everything
├── ops.yml                         # Day-2 operations (switchover, reinit, restart)
├── ansible.cfg                     # Ansible defaults (inventory path, SSH settings)
│
├── inventory/
│   └── hosts.ini                   # Static inventory (localhost for GCP provisioning)
│
├── group_vars/
│   └── all.yml                     # Cluster-wide variables (IPs, ports, PG params)
│
└── roles/
    │
    ├── gcp_instances/              # Role 1 — provision GCP VMs
    │   ├── defaults/
    │   │   └── main.yml            # Machine specs, zone map, venv paths
    │   ├── tasks/
    │   │   ├── main.yml            # Entry point — imports the two task files
    │   │   ├── setup_venv.yml      # Install apt deps, create GCP + kubespray venvs
    │   │   └── create_instances.yml # Pre-flight → create VMs → wait SSH → inventory
    │   └── templates/
    │       ├── masters-inventory.j2     # Ansible INI inventory output
    │       └── kubespray-inventory.j2  # Kubespray hosts.yaml output
    │
    ├── etcd/                       # Role 2 — install and configure etcd cluster
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/
    │       ├── etcd.conf.j2
    │       └── etcd.service.j2
    │
    ├── postgresql/                 # Role 3 — install PostgreSQL (Patroni manages it)
    │   └── tasks/main.yml
    │
    ├── patroni/                    # Role 4 — install Patroni, bootstrap cluster
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/
    │       ├── patroni.yml.j2
    │       └── patroni.service.j2
    │
    └── haproxy/                    # Role 5 — install HAProxy load balancer
        ├── tasks/main.yml
        ├── handlers/main.yml
        └── templates/
            └── haproxy.cfg.j2
```

---

## 4. Prerequisites

### Control Machine (where you run Ansible)

| Requirement | Version | Check |
|---|---|---|
| Ansible | 2.12+ | `ansible --version` |
| Python | 3.8+ | `python3 --version` |
| gcloud CLI | Any | `gcloud --version` |
| GCP ADC | — | `gcloud auth application-default login` |

### GCP Setup

```bash
# 1. Authenticate to GCP
gcloud auth application-default login

# 2. Set your project
gcloud config set project YOUR_PROJECT_ID

# 3. Enable required APIs
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
```

### Target Nodes

- Ubuntu 22.04 LTS
- SSH access with sudo privileges
- Nodes reachable from the control machine

### Required Ansible Collections

```bash
ansible-galaxy collection install google.cloud
```

---

## 5. Configuration Reference

All variables are in `roles/gcp_instances/defaults/main.yml` (GCP provisioning) and `group_vars/all.yml` (cluster configuration). Every IP, port, password, and PostgreSQL parameter has a dedicated variable — you never need to edit templates or task files directly.

### 5.1 GCP Provisioning Variables (`defaults/main.yml`)

```yaml
# GCP auth
adc_file: "/home/seang/.config/gcloud/application_default_credentials.json"
google_project_id: "your-project-id"
agent_user: "seang"

# Virtual environments
gcp_venv_dir: "/opt/venv/gcp"
kubespray_venv_dir: "/opt/venv/kubespray"

# Machine definitions
machine_specs:
  primary01:
    machine_type: "e2-standard-2"   # 2 vCPU, 8 GB RAM
    zone: "asia-east1-b"
    disk_size: 50                   # GB
    disk_type: "pd-standard"

# OS images
ubuntu_specs:
  v22:
    image: "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"

# What gets created (references machine_specs above)
machines_info:
  - name: "primary01"
    role: "master"                  # → kube_control_plane + PostgreSQL primary candidate
    machine_type: "{{ machine_specs.primary01.machine_type }}"
    zone: "{{ machine_specs.primary01.zone }}"
    ...
```

### 5.2 Cluster Variables (`group_vars/all.yml`)

```yaml
# Node IPs (must match your actual nodes after provisioning)
node_ips:
  pg-node1: "192.168.1.101"
  pg-node2: "192.168.1.102"
  pg-node3: "192.168.1.103"

# Ports
postgresql_port: 5432
patroni_api_port: 8008
haproxy_primary_port: 5000
haproxy_replica_port: 5001

# PostgreSQL tuning
pg_shared_buffers: "1GB"           # ~25% of RAM
pg_effective_cache_size: "3GB"     # ~75% of RAM
pg_max_connections: 200
pg_work_mem: "16MB"

# Patroni HA settings
patroni_ttl: 30                    # leader lock TTL (seconds)
patroni_loop_wait: 10              # how often Patroni checks the lock
patroni_max_lag_on_failover: 1048576  # max replica lag before excluded from election (bytes)

# Credentials — use Ansible Vault in production
postgres_superuser_password: "SecurePostgresPassword123!"
replicator_password: "SecureReplicatorPassword123!"
admin_password: "SecureAdminPassword123!"
```

### 5.3 Securing Credentials with Ansible Vault

```bash
# Encrypt a single value
ansible-vault encrypt_string 'MySecretPass' --name postgres_superuser_password

# Create a separate vault file
ansible-vault create group_vars/vault.yml
# Then reference in group_vars/all.yml:
#   postgres_superuser_password: "{{ vault_postgres_superuser_password }}"

# Run playbook with vault password
ansible-playbook site.yml --ask-vault-pass
# or store password in a file:
ansible-playbook site.yml --vault-password-file ~/.vault_pass
```

---

## 6. Deployment Guide

### Step 1 — Configure Variables

```bash
# Clone the project
git clone <repo-url> ha-postgres-gcp
cd ha-postgres-gcp

# Edit GCP provisioning settings
vim roles/gcp_instances/defaults/main.yml
# → Set google_project_id, agent_user, machine zones

# Edit cluster settings
vim group_vars/all.yml
# → Set node IPs, passwords, PostgreSQL tuning
```

### Step 2 — Authenticate to GCP

```bash
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
```

### Step 3 — Run the Full Deployment

```bash
# Dry-run first to see what will change
ansible-playbook site.yml --check

# Full deployment
ansible-playbook site.yml
```

### Step 4 — Verify the Deployment

```bash
# SSH into any cluster node
ssh seang@<node-ip>

# Check Patroni cluster status
patronictl -c /etc/patroni/patroni.yml list

# Expected output:
# + Cluster: postgres-cluster ----+----+-----------+
# | Member    | Host         | Role    | State   | TL | Lag in MB |
# +-----------+--------------+---------+---------+----+-----------+
# | pg-node1  | 192.168.1.101| Leader  | running |  1 |           |
# | pg-node2  | 192.168.1.102| Replica | running |  1 |         0 |
# | pg-node3  | 192.168.1.103| Replica | running |  1 |         0 |
# +-----------+--------------+---------+---------+----+-----------+
```

### Running Individual Stages

```bash
# Only provision GCP instances
ansible-playbook site.yml --tags provision

# Only setup Python venvs
ansible-playbook site.yml --tags venv

# Only deploy/reconfigure etcd
ansible-playbook site.yml --limit etcd

# Only deploy/reconfigure HAProxy
ansible-playbook site.yml --limit haproxy

# Only update Patroni configuration
ansible-playbook site.yml --limit patroni
```

---

## 7. Connecting to the Database

### 7.1 The Golden Rule

**Always connect through HAProxy, never directly to a node IP.**  
HAProxy continuously polls the Patroni REST API (`/primary`, `/replica`) and always knows which node is the current leader. If a failover happens, your application reconnects through the same HAProxy IP and transparently lands on the new primary.

```
Application
    │
    ├── WRITES → HAProxy :5000  ──► current primary (only)
    └── READS  → HAProxy :5001  ──► any healthy replica (round-robin)
```

### 7.2 Connection Strings

Replace `<haproxy-ip>`, `<password>`, and `<dbname>` with your values.

#### For Write Operations (Primary)

```
# Generic URI format
postgresql://<user>:<password>@<haproxy-ip>:5000/<dbname>

# Example
postgresql://postgres:SecurePostgresPassword123!@192.168.1.100:5000/myapp
```

#### For Read Operations (Replicas)

```
postgresql://postgres:SecurePostgresPassword123!@192.168.1.100:5001/myapp
```

#### For All Nodes (primary + replicas)

```
postgresql://postgres:SecurePostgresPassword123!@192.168.1.100:5002/myapp
```

---

### 7.3 Connecting with psql

```bash
# Connect to primary (read-write)
psql -h 192.168.1.100 -p 5000 -U postgres -d myapp

# Connect to replica (read-only)
psql -h 192.168.1.100 -p 5001 -U postgres -d myapp

# Verify which node you landed on
SELECT inet_server_addr(), pg_is_in_recovery();
#   inet_server_addr | pg_is_in_recovery
#  ------------------+-------------------
#   192.168.1.101    | f                 ← false = primary
#   192.168.1.102    | t                 ← true  = replica
```

---

### 7.4 Application Connection Examples

#### Python — psycopg2

```python
import psycopg2

# Write connection (always goes to primary)
write_conn = psycopg2.connect(
    host="192.168.1.100",
    port=5000,
    dbname="myapp",
    user="postgres",
    password="SecurePostgresPassword123!",
    connect_timeout=5,
    keepalives=1,
    keepalives_idle=30,
    keepalives_interval=5,
    keepalives_count=3,
)

# Read connection (round-robin across replicas)
read_conn = psycopg2.connect(
    host="192.168.1.100",
    port=5001,
    dbname="myapp",
    user="postgres",
    password="SecurePostgresPassword123!",
    options="-c default_transaction_read_only=on",  # safety: prevent writes
)
```

#### Python — SQLAlchemy

```python
from sqlalchemy import create_engine

# Write engine
write_engine = create_engine(
    "postgresql+psycopg2://postgres:SecurePostgresPassword123!@192.168.1.100:5000/myapp",
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,       # drop stale connections automatically
    pool_recycle=3600,        # recycle connections every hour
)

# Read engine
read_engine = create_engine(
    "postgresql+psycopg2://postgres:SecurePostgresPassword123!@192.168.1.100:5001/myapp",
    pool_size=20,             # more connections for reads
    max_overflow=40,
    pool_pre_ping=True,
    pool_recycle=3600,
    execution_options={"isolation_level": "AUTOCOMMIT"},
)
```

#### Node.js — node-postgres (pg)

```javascript
const { Pool } = require('pg');

// Write pool → primary
const writePool = new Pool({
  host: '192.168.1.100',
  port: 5000,
  database: 'myapp',
  user: 'postgres',
  password: 'SecurePostgresPassword123!',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

// Read pool → replicas
const readPool = new Pool({
  host: '192.168.1.100',
  port: 5001,
  database: 'myapp',
  user: 'postgres',
  password: 'SecurePostgresPassword123!',
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

// Usage
async function writeData() {
  const client = await writePool.connect();
  try {
    await client.query('INSERT INTO events(name) VALUES($1)', ['test']);
  } finally {
    client.release();
  }
}

async function readData() {
  const { rows } = await readPool.query('SELECT * FROM events LIMIT 10');
  return rows;
}
```

#### Go — pgx

```go
package main

import (
    "context"
    "github.com/jackc/pgx/v5/pgxpool"
)

func main() {
    ctx := context.Background()

    // Write pool
    writeCfg, _ := pgxpool.ParseConfig(
        "postgres://postgres:SecurePostgresPassword123!@192.168.1.100:5000/myapp",
    )
    writeCfg.MaxConns = 10
    writePool, _ := pgxpool.NewWithConfig(ctx, writeCfg)
    defer writePool.Close()

    // Read pool
    readCfg, _ := pgxpool.ParseConfig(
        "postgres://postgres:SecurePostgresPassword123!@192.168.1.100:5001/myapp",
    )
    readCfg.MaxConns = 20
    readPool, _ := pgxpool.NewWithConfig(ctx, readCfg)
    defer readPool.Close()
}
```

#### Java — JDBC

```java
// Write datasource (primary)
String writeUrl = "jdbc:postgresql://192.168.1.100:5000/myapp" +
                  "?user=postgres" +
                  "&password=SecurePostgresPassword123!" +
                  "&socketTimeout=30" +
                  "&connectTimeout=5" +
                  "&loginTimeout=5";

// Read datasource (replicas)
String readUrl  = "jdbc:postgresql://192.168.1.100:5001/myapp" +
                  "?user=postgres" +
                  "&password=SecurePostgresPassword123!" +
                  "&defaultRowFetchSize=100";
```

#### .env File Template

```bash
# .env — copy and fill in your values
DB_WRITE_HOST=192.168.1.100
DB_WRITE_PORT=5000
DB_READ_HOST=192.168.1.100
DB_READ_PORT=5001
DB_NAME=myapp
DB_USER=postgres
DB_PASSWORD=SecurePostgresPassword123!
DB_POOL_SIZE_WRITE=10
DB_POOL_SIZE_READ=20
```

---

### 7.5 Connection Recommendations

| Concern | Recommendation |
|---|---|
| **Always use pool_pre_ping / keepalives** | Detects dead connections after a failover immediately |
| **Separate write and read pools** | Prevents reads from adding load to the primary |
| **Set connect_timeout** | Fail fast rather than hanging for minutes |
| **Use the `admin` user for app setup** | Has `CREATEDB` and `CREATEROLE`; use `postgres` only for DBA tasks |
| **Never connect directly to node IPs** | HAProxy handles failover transparently; direct connections won't |
| **Set `default_transaction_read_only=on`** on read connections | Prevents accidental writes going to a replica (which would fail anyway, but this makes errors clearer) |

---

## 8. Cluster Operations

### 8.1 Check Cluster Status

```bash
# From any cluster node
patronictl -c /etc/patroni/patroni.yml list

# Via the REST API (from anywhere with network access)
curl -s http://192.168.1.101:8008/cluster | jq
curl -s http://192.168.1.101:8008/leader  | jq

# Health check — returns HTTP 200 if the node is healthy
curl -s -o /dev/null -w "%{http_code}" http://192.168.1.101:8008/health

# Check if a specific node is primary (returns 200) or replica (returns 503)
curl -s -o /dev/null -w "%{http_code}" http://192.168.1.101:8008/primary

# HAProxy stats page
open http://192.168.1.100:7000/stats
```

### 8.2 Planned Switchover (no data loss)

```bash
# Interactive mode
patronictl -c /etc/patroni/patroni.yml switchover

# Non-interactive — switch leader to pg-node2
ansible-playbook ops.yml --tags switchover -e "candidate=pg-node2"

# Or directly
patronictl -c /etc/patroni/patroni.yml switchover \
  --leader pg-node1 \
  --candidate pg-node2 \
  --force
```

### 8.3 Emergency Failover

```bash
# Force failover (use when primary is unresponsive)
ansible-playbook ops.yml --tags failover

# Or directly
patronictl -c /etc/patroni/patroni.yml failover postgres-cluster --force
```

### 8.4 Reinitialise a Corrupted / Lagging Replica

```bash
# Via ops.yml
ansible-playbook ops.yml --tags reinit -e "target_node=pg-node3"

# Or directly — this wipes the replica's data and reclones from the leader
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster pg-node3 --force
```

### 8.5 Rolling Restart (apply PostgreSQL config changes)

```bash
# Via ops.yml
ansible-playbook ops.yml --tags rolling_restart

# Or directly
patronictl -c /etc/patroni/patroni.yml restart postgres-cluster --force
```

### 8.6 Edit Cluster Configuration Dynamically

```bash
# Opens $EDITOR with the current DCS config — changes apply to all nodes live
patronictl -c /etc/patroni/patroni.yml edit-config

# Show current DCS config
patronictl -c /etc/patroni/patroni.yml show-config

# Show history of leader changes
patronictl -c /etc/patroni/patroni.yml history
```

---

## 9. Monitoring

### 9.1 Replication Status Queries

Run these on the **primary** to check replication health:

```sql
-- Replication lag per replica
SELECT
    client_addr,
    state,
    sent_lsn,
    replay_lsn,
    pg_size_pretty(
        pg_wal_lsn_diff(sent_lsn, replay_lsn)
    ) AS lag
FROM pg_stat_replication;

-- Replication slots
SELECT
    slot_name,
    active,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    ) AS retained_wal
FROM pg_replication_slots;
```

Run this on a **replica** to verify it is streaming:

```sql
SELECT
    pg_is_in_recovery()           AS is_replica,
    pg_last_wal_receive_lsn()     AS received_lsn,
    pg_last_wal_replay_lsn()      AS replayed_lsn,
    now() - pg_last_xact_replay_timestamp() AS replication_delay;
```

### 9.2 Useful Log Commands

```bash
# Patroni logs (live)
sudo journalctl -u patroni -f

# PostgreSQL logs
sudo tail -f /var/log/postgresql/postgresql-$(date +%Y-%m-%d).log

# etcd logs
sudo journalctl -u etcd -f

# HAProxy logs
sudo journalctl -u haproxy -f
```

---

## 10. Troubleshooting

### Patroni service fails to start

```bash
# Check logs
sudo journalctl -u patroni -n 50

# Common causes:
# 1. etcd unreachable
etcdctl endpoint health --endpoints=http://192.168.1.101:2379,http://192.168.1.102:2379,http://192.168.1.103:2379

# 2. Wrong file permissions
sudo chown -R postgres:postgres /etc/patroni /var/lib/patroni
sudo chmod 600 /etc/patroni/patroni.yml

# 3. Port already in use
sudo ss -tlnp | grep -E "5432|8008"
```

### Replica not streaming

```bash
# Check replication status on primary
psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Reinitialise the replica if it has diverged too far
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster pg-node2 --force
```

### etcd cluster unhealthy

```bash
# Check member list
etcdctl member list

# If a single node is down, restart it
sudo systemctl restart etcd

# If the cluster is split-brained (multiple leaders), stop all, clear data, restart
sudo systemctl stop etcd           # on all nodes
sudo rm -rf /var/lib/etcd/default  # on all nodes — WARNING: loses cluster state
sudo systemctl start etcd          # on all nodes simultaneously
```

### GCP zone exhausted during provisioning

The `gcp_instances` role handles this automatically in two stages:

1. **Pre-flight (stage 1)** — before creating anything, it checks zone availability and remaps any down/exhausted zone to a different region entirely (not just a different zone in the same region)
2. **Safety net (stage 2)** — if a create call fails with `ZONE_RESOURCE_POOL_EXHAUSTED` anyway, it releases the reserved IP, picks a zone from a completely different region, reserves a new IP there, and retries

If you see repeated exhaustion failures, manually update the zone in `defaults/main.yml` and re-run:

```bash
ansible-playbook site.yml --tags provision
```

### HAProxy shows all backends as DOWN

```bash
# Check that Patroni REST API is responding on all nodes
for ip in 192.168.1.101 192.168.1.102 192.168.1.103; do
  echo -n "$ip /primary → "
  curl -s -o /dev/null -w "%{http_code}\n" http://$ip:8008/primary
done

# Validate HAProxy config
sudo haproxy -c -f /etc/haproxy/haproxy.cfg

# Restart HAProxy
sudo systemctl restart haproxy
```

### Connection refused from application

```bash
# Confirm HAProxy is listening on the expected ports
sudo ss -tlnp | grep haproxy

# Test with psql directly
psql -h 192.168.1.100 -p 5000 -U postgres -c "SELECT 1;"

# Check GCP firewall rules — ports 5000, 5001, 5432 must be open to your application
gcloud compute firewall-rules list --project YOUR_PROJECT_ID
```