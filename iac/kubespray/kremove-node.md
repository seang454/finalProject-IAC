# Kubespray — Remove Dead Master Nodes Recovery Runbook

## Scenario
- `master01` and `master02` are permanently unavailable due to GCP zone error
- `master-seang` is the only surviving control plane node
- Workers are still running
- Goal: Clean up dead masters and restore single-node control plane

---

## Current State

```
master-seang  34.126.125.84  10.148.0.7   ✅ UP   (surviving master)
master01      34.84.181.61   10.146.0.5   ❌ DOWN (GCP zone error)
master02      35.244.40.133  10.160.0.9   ❌ DOWN (GCP zone error)

worker01      34.22.93.174                ✅ UP
worker02      34.129.8.124                ✅ UP
worker03      34.126.203.159              ✅ UP
```

---

## Full Recovery Flow

```
etcd stuck (no quorum — 2 of 3 members unreachable)
        │
        ▼
Step 1: Run recover-etcd-single-node.sh
        Force etcd to single node on master-seang
        Restart kubelet to recover API server
        │
        ▼
Step 2: remove-node.yml for master01
        Clean up Kubespray state for master01
        │
        ▼
Step 3: remove-node.yml for master02
        Clean up Kubespray state for master02
        │
        ▼
Step 4: kubectl delete node
        Remove dead nodes from Kubernetes
        │
        ▼
Step 5: Verify cluster is healthy
        │
        ▼
        Cluster stable with 1 master ✅
        (Add new masters via scale.yml to restore HA)
```

---

## Step 1 — Run etcd Recovery Script

This script forces etcd to run as a single node on master-seang,
removes dead etcd members, and restarts kubelet to recover the API server.

```bash
sudo bash recover-etcd-single-node.sh
```

### What the script does internally:
- Stops etcd service
- Updates `/etc/etcd.env` — removes etcd2 and etcd3 from `ETCD_INITIAL_CLUSTER`
- Forces etcd to start as single node with `--force-new-cluster`
- Removes dead members (etcd2=master01, etcd3=master02) from etcd membership
- Hands etcd back to systemd
- Restarts kubelet so kube-apiserver static pod recovers
- Verifies `kubectl get nodes` is accessible

> ⚠️ Run this on **master-seang only**
> ⚠️ Script does NOT touch master01 or master02 VMs — they are already down

---

## Step 2 — Remove master01 via Kubespray

This cleans up Kubespray's internal state for master01.
Since master01 is unreachable, we use `skip_drain=true` and `ignore_errors=yes`
so Ansible does not hang waiting for SSH timeout.

```bash
ansible-playbook -i inventory/sample/inventory.ini \
  remove-node.yml \
  -b -v \
  --private-key=~/.ssh/id_rsa \
  -e "node=master01" \
  -e "ignore_errors=yes" \
  -e "skip_drain=true"
```

### Flags explained:
| Flag | Why |
|---|---|
| `node=master01` | Target only master01 |
| `ignore_errors=yes` | Don't stop on SSH failures (node is unreachable) |
| `skip_drain=true` | Skip drain step — node is already down, nothing to drain |

> ⚠️ This may show warnings and errors — that is expected since the node is unreachable
> ⚠️ If it hangs more than 5 minutes press `Ctrl+C` and proceed to Step 3

---

## Step 3 — Remove master02 via Kubespray

Same as Step 2 but for master02.

```bash
ansible-playbook -i inventory/sample/inventory.ini \
  remove-node.yml \
  -b -v \
  --private-key=~/.ssh/id_rsa \
  -e "node=master02" \
  -e "ignore_errors=yes" \
  -e "skip_drain=true"
```

> ⚠️ Same behavior as Step 2 — errors are expected, proceed even if it fails

---

## Step 4 — Delete Dead Nodes from Kubernetes

This removes master01 and master02 from the Kubernetes node registry.
This command does NOT need SSH to the dead VMs — it only talks to the API server.

```bash
kubectl delete node master01
kubectl delete node master02
```

> ✅ This is instant — no waiting for SSH timeout
> ✅ This is all that is strictly required if Steps 2 and 3 fail or hang

---

## Step 5 — Verify Cluster is Healthy

```bash
# Check all nodes
kubectl get nodes -o wide
```

Expected output:
```
NAME           STATUS   ROLES           AGE   VERSION
master-seang   Ready    control-plane   Xd    v1.xx.x   ✅
worker01       Ready    worker          Xd    v1.xx.x   ✅
worker02       Ready    worker          Xd    v1.xx.x   ✅
worker03       Ready    worker          Xd    v1.xx.x   ✅
```

```bash
# Check all pods are running
kubectl get pods -A
```

```bash
# Check etcd health
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-master-seang.pem \
  --key=/etc/ssl/etcd/ssl/admin-master-seang-key.pem \
  endpoint health
```

---

## Step 6 — Clean Up inventory.ini

Remove `master01`, `master02` and `[broken_etcd]` section entirely.

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

## Step 7 — Restore HA (Add New Masters)

Once the cluster is stable, provision 2 new GCP VMs in a working zone
and add them as new master nodes.

### 7a. Update inventory.ini with new masters

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

### 7b. Run scale.yml targeting new masters only

```bash
ansible-playbook -i inventory/sample/inventory.ini \
  scale.yml \
  -b -v \
  --private-key=~/.ssh/id_rsa \
  --limit=new-master01,new-master02
```

> ⚠️ Always use `--limit` to target new nodes only

---

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `remove-node.yml` hangs | Trying to SSH into dead VM | Press `Ctrl+C`, proceed to `kubectl delete node` |
| `kubectl get nodes` refused | API server not up yet | Wait 2 min, check `sudo systemctl status kubelet` |
| etcd not starting | Old cluster state conflict | Check `sudo journalctl -xeu etcd.service -n 30` |
| Workers show NotReady | Lost connection during recovery | Wait 2-3 min, kubelet reconnects automatically |
| scale.yml fails on new masters | Wrong IP or SSH key | Verify `ansible -m ping` on new masters first |

---

## Important Notes

- `kubectl delete node` does NOT affect the VM — it only removes it from Kubernetes registry
- `remove-node.yml` does NOT SSH into dead VMs when `ignore_errors=yes` is set — errors are expected
- master01 and master02 VMs are down because of **GCP zone error** — not because of any script
- The recovery script only touches **master-seang** — it never connects to dead VMs
- After recovery, cluster runs with **1 control plane** — not HA until new masters are added via `scale.yml`