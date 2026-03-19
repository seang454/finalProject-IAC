# PostgreSQL HA Cluster – Ansible Playbook

Automated deployment of a **3-node PostgreSQL High-Availability cluster** using
**Patroni + etcd + HAProxy** on Ubuntu 22.04 / 24.04.

```
                    ┌─────────────────────┐
   App (writes) ──► │  HAProxy :5000      │
   App (reads)  ──► │  HAProxy :5001      │
                    └────────┬────────────┘
                             │  health-checks Patroni REST API (:8008)
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │ pg-node1 │  │ pg-node2 │  │ pg-node3 │
        │ Leader   │  │ Replica  │  │ Replica  │
        │ Patroni  │  │ Patroni  │  │ Patroni  │
        │ etcd     │◄─┤ etcd     ├─►│ etcd     │
        └──────────┘  └──────────┘  └──────────┘
```

## Directory Layout

```
patroni-ha-cluster/
├── ansible.cfg                  # Ansible defaults
├── site.yml                     # Main playbook (full cluster setup)
├── failover.yml                 # Manual switchover / forced failover
├── reinit-replica.yml           # Reclone a corrupted / lagging replica
├── inventory/
│   └── hosts.ini                # ← Edit: your node IPs
├── group_vars/
│   ├── all.yml                  # ← Edit: all tunable variables
│   └── vault.yml                # ← Encrypt with ansible-vault
└── roles/
    ├── etcd/                    # Install & configure etcd
    ├── postgresql/              # Install PostgreSQL (Patroni-managed)
    ├── patroni/                 # Install Patroni + deploy config
    └── haproxy/                 # Install & configure HAProxy
```

## Quick Start

### 1. Set your IPs and passwords

Edit **`group_vars/all.yml`** – at minimum change these sections:

```yaml
# Node IP map  (hostname → IP)
patroni_nodes:
  pg-node1: "192.168.1.101"
  pg-node2: "192.168.1.102"
  pg-node3: "192.168.1.103"

haproxy_ip: "192.168.1.100"

# Credentials – move to vault.yml and encrypt!
postgresql_superuser_password: "change-me"
postgresql_replicator_password: "change-me"
postgresql_admin_password:      "change-me"
```

Update **`inventory/hosts.ini`** to match your hostnames and IPs:

```ini
[patroni_cluster]
pg-node1 ansible_host=192.168.1.101
pg-node2 ansible_host=192.168.1.102
pg-node3 ansible_host=192.168.1.103

[haproxy]
haproxy-node ansible_host=192.168.1.100
```

### 2. (Recommended) Encrypt secrets with Ansible Vault

```bash
ansible-vault encrypt group_vars/vault.yml
# Then reference vault variables in all.yml:
# postgresql_superuser_password: "{{ vault_postgresql_superuser_password }}"
```

### 3. Run the full playbook

```bash
# Plain run
ansible-playbook site.yml

# With vault password
ansible-playbook site.yml --ask-vault-pass

# Dry run first
ansible-playbook site.yml --check --diff
```

### 4. Run individual stages with tags

| Tag | What it does |
|-----|-------------|
| `common` | Configure `/etc/hosts` on all nodes |
| `etcd` | Install and start etcd cluster |
| `postgresql` | Install PostgreSQL packages |
| `patroni` | Deploy Patroni config and start service |
| `patroni-leader` | Bootstrap the first node only |
| `patroni-replicas` | Join remaining nodes |
| `haproxy` | Deploy load balancer |
| `verify` | Assert cluster health |

```bash
ansible-playbook site.yml --tags etcd,postgresql
ansible-playbook site.yml --tags verify
```

## Connection Endpoints (via HAProxy)

| Port | Purpose | Notes |
|------|---------|-------|
| `5000` | Read-Write (primary only) | Use for all writes |
| `5001` | Read-Only (replicas, round-robin) | Use for read scaling |
| `5002` | All nodes | Fallback / general |
| `7000` | HAProxy stats UI | `http://<haproxy-ip>:7000/stats` |

```bash
# Write connection
psql -h 192.168.1.100 -p 5000 -U postgres -d mydb

# Read connection
psql -h 192.168.1.100 -p 5001 -U postgres -d mydb
```

## Day-2 Operations

### Graceful switchover (planned maintenance)
```bash
# Switch leadership to pg-node2
ansible-playbook failover.yml -e "failover_candidate=pg-node2"

# Let Patroni choose the best candidate
ansible-playbook failover.yml
```

### Forced failover (leader is down)
```bash
ansible-playbook failover.yml -e "force_failover=true" -e "failover_candidate=pg-node2"
```

### Reinitialise a corrupted / lagging replica
```bash
ansible-playbook reinit-replica.yml -e "target_node=pg-node3"
```

### Check cluster status manually
```bash
# From any cluster node
patronictl -c /etc/patroni/patroni.yml list

# Via REST API
curl -s http://192.168.1.101:8008/cluster | jq
```

## Key Variables Reference (`group_vars/all.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `patroni_nodes` | `{pg-node1: ..., ...}` | Node name → IP map |
| `postgresql_version` | `16` | PostgreSQL major version |
| `postgresql_port` | `5432` | PostgreSQL listen port |
| `patroni_cluster_name` | `postgres-cluster` | Cluster scope name |
| `patroni_restapi_port` | `8008` | Patroni REST API port |
| `patroni_ttl` | `30` | Leader lock TTL (seconds) |
| `patroni_loop_wait` | `10` | Leader lock refresh interval |
| `patroni_max_lag_on_failover` | `1048576` | Max replica lag for failover (bytes) |
| `etcd_client_port` | `2379` | etcd client port |
| `etcd_peer_port` | `2380` | etcd peer port |
| `pg_shared_buffers` | `1GB` | PostgreSQL shared_buffers |
| `pg_max_connections` | `200` | PostgreSQL max_connections |
| `haproxy_primary_port` | `5000` | HAProxy primary (write) port |
| `haproxy_replica_port` | `5001` | HAProxy replica (read) port |
| `haproxy_stats_port` | `7000` | HAProxy stats page port |

## Requirements

- Ubuntu 22.04 or 24.04 on all nodes
- Ansible ≥ 2.14 on the control machine (`pip install ansible`)
- SSH key-based access from control machine to all nodes
- Ports open between nodes: `5432`, `8008`, `2379`, `2380`
