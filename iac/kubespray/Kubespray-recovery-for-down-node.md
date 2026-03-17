# Kubespray Control Plane Recovery Runbook

## Scenario
Two master nodes are permanently down (e.g. GCP zone error — VM cannot be restarted).
Recover the cluster without resetting everything.

```
master-seang  34.126.125.84  10.148.0.7   ✅ UP   (surviving master)
master01      34.84.181.61   10.146.0.5   ❌ DOWN (GCP zone error — unreachable)
master02      35.244.40.133  10.160.0.9   ❌ DOWN (GCP zone error — unreachable)

worker01      34.22.93.174                ✅ UP
worker02      34.129.8.124                ✅ UP
worker03      34.126.203.159              ✅ UP
```

---

## Why NOT Reset the Whole Cluster

| Action | Impact |
|---|---|
| `reset.yml` + `cluster.yml` | ❌ Destroys all workloads, PVs, configs — nuclear option |
| Manual etcd recovery + `kubectl delete node` | ✅ Workers and workloads stay running |

> **Rule:** Only reset if the cluster is completely unrecoverable.

---

## Which Recovery Method to Use

```
Masters are down
        │
        ▼
Can you SSH into the dead masters?
        │
        ├── ✅ YES → use recover-control-plane.yml
        │           Ansible can gather facts, playbook handles everything
        │
        └── ❌ NO  → use Manual Recovery (this runbook)
                    VMs gone or unreachable — SSH times out
```

---

## Method A — `recover-control-plane.yml` (nodes still SSH reachable)

Use this when dead masters are still reachable via SSH — for example the etcd
process crashed but the VM is still running.

### Step A1 — Edit inventory.ini

Add `[broken_etcd]` group with the dead masters and remove them from `[kube_control_plane]`:

```ini
[kube_control_plane]
master-seang  ansible_host=34.126.125.84  ip=10.148.0.7  etcd_member_name=etcd1

[broken_etcd]
master01  ansible_host=34.84.181.61   ip=10.146.0.5  access_ip=10.146.0.5  etcd_member_name=etcd2
master02  ansible_host=35.244.40.133  ip=10.160.0.9  access_ip=10.160.0.9  etcd_member_name=etcd3

[etcd:children]
kube_control_plane

[kube_node]
worker01  ansible_host=34.22.93.174   ip=34.22.93.174
worker02  ansible_host=34.129.8.124   ip=34.129.8.124
worker03  ansible_host=34.126.203.159 ip=34.126.203.159

[k8s_cluster:children]
kube_control_plane
kube_node
```

> ⚠️ `access_ip=` must be set on broken_etcd nodes — required for `main_access_ip` variable
> ⚠️ Workers must have `ip=` uncommented — required for `etcd_access_addresses` template
> ⚠️ No `←` arrow characters or trailing text on host lines — causes parse error

### Step A2 — Run `recover-control-plane.yml`

```bash
ansible-playbook -i inventory/sample/inventory.ini \
  recover-control-plane.yml \
  -b -v \
  --private-key=~/.ssh/id_rsa
```

What this playbook does internally:
- Connects to `[broken_etcd]` nodes and checks etcd health
- Removes broken members from etcd cluster
- Forces etcd quorum on surviving `[kube_control_plane]` node
- Restores API server

### Step A3 — Verify

```bash
kubectl get nodes -o wide
```

### When `recover-control-plane.yml` Will Fail

| Cause | Error |
|---|---|
| Dead masters unreachable via SSH | `main_access_ip` undefined — etcd_access_addresses template fails |
| `ip=` commented out on workers | `main_access_ip` undefined for worker nodes |
| `←` arrow in inventory.ini | `Expected key=value host variable assignment` parse error |
| `[broken_etcd]` group missing | `dict object has no attribute broken_etcd` |
| `access_ip=` missing on broken_etcd nodes | `main_access_ip` undefined |

---

## Method B — Manual Recovery (nodes unreachable — this scenario)

Use this when dead master VMs are completely gone or unreachable via SSH.

### Full Recovery Flow

```
etcd stuck — no quorum (2 of 3 members unreachable)
kubectl → connection refused to 127.0.0.1:6443
        │
        ▼
Step B1: Run recover-etcd-single-node.sh
         Force etcd single node on master-seang
         Restart kubelet → API server recovers
        │
        ▼
Step B2: remove-node.yml for master01
         Clean up Kubespray state (may hang — use Ctrl+C)
        │
        ▼
Step B3: remove-node.yml for master02
         Clean up Kubespray state (may hang — use Ctrl+C)
        │
        ▼
Step B4: kubectl delete node master01 master02
         Remove from Kubernetes registry (instant, no SSH needed)
        │
        ▼
Step B5: Clean up inventory.ini
        │
        ▼
Step B6: Verify cluster healthy
        │
        ▼
Step B7: Add new masters via scale.yml (restore HA)
        │
        ▼
        Cluster fully HA again ✅
```

---

### Step B1 — Run etcd Recovery Script

> ⚠️ Run on **master-seang only** — does NOT touch master01 or master02

```bash
sudo bash recover-etcd-single-node.sh
```

#### What the script does internally

```
Stop etcd service
        ↓
Update /etc/etcd.env:
  ETCD_INITIAL_CLUSTER = etcd1 only (remove etcd2 and etcd3)
        ↓
Start etcd with --force-new-cluster + full TLS flags
  (must pass all TLS flags explicitly — sourcing env file alone is not enough)
        ↓
Verify etcd responds via etcdctl
        ↓
Remove dead members (etcd2=master01, etcd3=master02) via etcdctl member remove
        ↓
Stop manual etcd → hand back to systemd
        ↓
sudo systemctl restart kubelet
  ← kube-apiserver is a STATIC POD managed by kubelet
  ← NOT a systemd service — restart kubelet to recover it
  ← sudo systemctl restart kube-apiserver = Unit not found ❌
        ↓
Wait for kube-apiserver static pod to come up via crictl
        ↓
Verify kubectl get nodes
```

---

### Step B2 — Remove master01 via Kubespray

```bash
ansible-playbook -i inventory/sample/inventory.ini \
  remove-node.yml \
  -b -v \
  --private-key=~/.ssh/id_rsa \
  -e "node=master01" \
  -e "ignore_errors=yes" \
  -e "skip_drain=true"
```

| Flag | Why |
|---|---|
| `node=master01` | Target only master01 |
| `ignore_errors=yes` | Don't fail on SSH errors — node is unreachable |
| `skip_drain=true` | Skip drain — node is already down |

> ⚠️ Errors are expected — node is unreachable
> ⚠️ If it hangs more than 5 minutes press `Ctrl+C` — `kubectl delete node` in Step B4 is sufficient

---

### Step B3 — Remove master02 via Kubespray

```bash
ansible-playbook -i inventory/sample/inventory.ini \
  remove-node.yml \
  -b -v \
  --private-key=~/.ssh/id_rsa \
  -e "node=master02" \
  -e "ignore_errors=yes" \
  -e "skip_drain=true"
```

---

### Step B4 — Delete Dead Nodes from Kubernetes

Does NOT need SSH to dead VMs — only talks to the API server. Always run this
even if Steps B2 and B3 completed or were cancelled.

```bash
kubectl delete node master01
kubectl delete node master02
```

---

### Step B5 — Clean Up inventory.ini

Remove `[broken_etcd]` section and dead masters entirely.

**Before:**
```ini
[kube_control_plane]
master-seang  ansible_host=34.126.125.84  ip=10.148.0.7  etcd_member_name=etcd1

[broken_etcd]
master01  ansible_host=34.84.181.61   ip=10.146.0.5  etcd_member_name=etcd2
master02  ansible_host=35.244.40.133  ip=10.160.0.9  etcd_member_name=etcd3

[etcd:children]
kube_control_plane

[kube_node]
worker01  ansible_host=34.22.93.174   ip=34.22.93.174
worker02  ansible_host=34.129.8.124   ip=34.129.8.124
worker03  ansible_host=34.126.203.159 ip=34.126.203.159

[k8s_cluster:children]
kube_control_plane
kube_node
```

**After:**
```ini
[kube_control_plane]
master-seang  ansible_host=34.126.125.84  ip=10.148.0.7  etcd_member_name=etcd1

[etcd:children]
kube_control_plane

[kube_node]
worker01  ansible_host=34.22.93.174   ip=34.22.93.174
worker02  ansible_host=34.129.8.124   ip=34.129.8.124
worker03  ansible_host=34.126.203.159 ip=34.126.203.159

[k8s_cluster:children]
kube_control_plane
kube_node
```

---

### Step B6 — Verify Cluster is Healthy

```bash
# Check nodes
kubectl get nodes -o wide

# Check all pods
kubectl get pods -A

# Check etcd health
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-master-seang.pem \
  --key=/etc/ssl/etcd/ssl/admin-master-seang-key.pem \
  endpoint health

# Check etcd members (should be etcd1 only)
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-master-seang.pem \
  --key=/etc/ssl/etcd/ssl/admin-master-seang-key.pem \
  member list -w table
```

Expected:
```
NAME           STATUS   ROLES           AGE
master-seang   Ready    control-plane   ✅
worker01       Ready    worker          ✅
worker02       Ready    worker          ✅
worker03       Ready    worker          ✅
```

---

### Step B7 — Restore HA (Add New Masters)

Provision 2 new GCP VMs in a working zone, then:

#### Update inventory.ini

```ini
[kube_control_plane]
master-seang  ansible_host=34.126.125.84  ip=10.148.0.7   etcd_member_name=etcd1
new-master01  ansible_host=NEW_PUBLIC_IP  ip=NEW_PRIVATE_IP  etcd_member_name=etcd2
new-master02  ansible_host=NEW_PUBLIC_IP  ip=NEW_PRIVATE_IP  etcd_member_name=etcd3

[etcd:children]
kube_control_plane

[kube_node]
worker01  ansible_host=34.22.93.174   ip=34.22.93.174
worker02  ansible_host=34.129.8.124   ip=34.129.8.124
worker03  ansible_host=34.126.203.159 ip=34.126.203.159

[k8s_cluster:children]
kube_control_plane
kube_node
```

#### Verify new masters are reachable

```bash
ansible -i inventory/sample/inventory.ini new-master01,new-master02 \
  -m ping --private-key=~/.ssh/id_rsa
```

#### Run scale.yml

```bash
ansible-playbook -i inventory/sample/inventory.ini \
  scale.yml \
  -b -v \
  --private-key=~/.ssh/id_rsa \
  --limit=new-master01,new-master02
```

---

## Playbook Reference

| Playbook | Use Case | When to Use |
|---|---|---|
| `cluster.yml` | Fresh cluster deployment | First time only |
| `cluster.yml --limit` | Re-apply config to existing nodes | Config changes on running nodes |
| `scale.yml --limit` | Add NEW nodes only | Scaling up or replacing nodes |
| `upgrade-cluster.yml` | Upgrade Kubernetes version | One minor version at a time only |
| `remove-node.yml` | Safely remove a node | Decommission or replace |
| `recover-control-plane.yml` | Recover degraded control plane | Masters broken but SSH reachable |
| `reset.yml` | ⚠️ Wipe entire cluster | Last resort — destroys everything |

---

## inventory.ini Section Reference

| Section | Purpose |
|---|---|
| `[kube_control_plane]` | Master/API server nodes |
| `[etcd:children]` | etcd members — stacked = same as masters |
| `[broken_etcd]` | Dead etcd nodes for `recover-control-plane.yml` — remove after recovery |
| `[kube_node]` | Worker nodes |
| `[k8s_cluster:children]` | Groups masters + workers — required for `group_vars/k8s_cluster/` |

---

## Common Mistakes

| Mistake | Result | Fix |
|---|---|---|
| Using `recover-control-plane.yml` when VMs unreachable | Hangs — `main_access_ip` undefined | Use manual etcd recovery instead |
| `←` arrow characters in inventory.ini | `Expected key=value` parse error — entire inventory fails | Remove all non `key=value` text from host lines |
| `ip=` commented out on workers | `main_access_ip` undefined — etcd template fails | Uncomment or set `ip=` to public IP to match first deploy |
| `[broken_etcd]` missing | `dict object has no attribute broken_etcd` | Add `[broken_etcd]` group with dead nodes |
| `access_ip=` missing on broken_etcd nodes | `main_access_ip` undefined | Add `access_ip=` same value as `ip=` |
| Missing `[k8s_cluster:children]` | `group_vars/k8s_cluster/` settings never apply | Add section at bottom of inventory.ini |
| `sudo systemctl restart kube-apiserver` | Unit not found | Use `sudo systemctl restart kubelet` instead |
| Running `scale.yml` without `--limit` | May reconfigure existing nodes | Always add `--limit=newnode` |
| Running `scale.yml` to update existing nodes | Changes silently skipped | Use `cluster.yml --limit=nodename` instead |
| Duplicate `[kube_control_plane]` header | Ansible parse error | Remove duplicate header |