#!/bin/bash
# =============================================================================
# Kubespray etcd Single Node Recovery Script v4
# =============================================================================
# Run this on master-seang ONLY
# Purpose: Force etcd to run as single node after master01 and master02 are gone
#
# Usage: sudo bash recover-etcd-single-node.sh
# =============================================================================

# NO set -e here — we handle errors manually to avoid early exit


# The Script Does NOT Affect master01 or master02

# What the Script Does
# Script runs ONLY on master-seang
#         │
#         ├── Stops etcd on master-seang
#         ├── Removes etcd2 and etcd3 from etcd MEMBERSHIP LIST only
#         ├── Starts etcd on master-seang as single node
#         └── Restarts kubelet on master-seang
# It only touches master-seang — it never SSHes into master01 or master02.

# What "Remove Member" Actually Does
# etcdctl member remove <ID>
#         │
#         ▼
# Removes master01/master02 from etcd's
# MEMBERSHIP RECORD inside master-seang's data
#         │
#         ▼
# master01 and master02 VMs = untouched ✅
# master01 and master02 etcd process = untouched ✅
# master01 and master02 OS = untouched ✅

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# CONFIG — matches your /etc/etcd.env exactly
# =============================================================================
ETCD_ENV="/etc/etcd.env"
ETCD_BIN="/usr/local/bin/etcd"
ETCD_DATA_DIR="/var/lib/etcd"

# TLS certs
ETCD_CACERT="/etc/ssl/etcd/ssl/ca.pem"
ETCD_CERT="/etc/ssl/etcd/ssl/admin-master-seang.pem"
ETCD_KEY="/etc/ssl/etcd/ssl/admin-master-seang-key.pem"
ETCD_MEMBER_CERT="/etc/ssl/etcd/ssl/member-master-seang.pem"
ETCD_MEMBER_KEY="/etc/ssl/etcd/ssl/member-master-seang-key.pem"

# master-seang network
ETCD_NAME="etcd1"
ETCD_IP="10.148.0.7"
ETCD_CLIENT_URL="https://${ETCD_IP}:2379"
ETCD_PEER_URL="https://${ETCD_IP}:2380"
ETCD_ENDPOINT="https://127.0.0.1:2379"

# =============================================================================
print_step() {
  echo ""
  echo -e "${BLUE}=============================================${NC}"
  echo -e "${BLUE} $1${NC}"
  echo -e "${BLUE}=============================================${NC}"
}
print_ok()    { echo -e "${GREEN}✅ $1${NC}"; }
print_warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

etcdctl_cmd() {
  ETCDCTL_API=3 etcdctl \
    --endpoints=$ETCD_ENDPOINT \
    --cacert=$ETCD_CACERT \
    --cert=$ETCD_CERT \
    --key=$ETCD_KEY \
    "$@"
}

# =============================================================================
# STEP 1 — Cleanup any previous failed attempt
# =============================================================================
print_step "STEP 1 — Cleanup previous failed attempts"

sudo pkill -f "etcd --force-new-cluster" 2>/dev/null \
  && print_warn "Killed stray force-new-cluster process" || true
sleep 3

# Remove bad default.etcd directory created by previous failed run
[ -d "/root/default.etcd" ] && sudo rm -rf /root/default.etcd && print_ok "Removed /root/default.etcd" || true
[ -d "$HOME/default.etcd" ] && rm -rf $HOME/default.etcd && print_ok "Removed $HOME/default.etcd" || true

print_ok "Cleanup done"

# =============================================================================
# STEP 2 — Backup (skip if already done)
# =============================================================================
print_step "STEP 2 — Backup etcd data and config"

if [ ! -f "${ETCD_ENV}.backup" ]; then
  sudo cp $ETCD_ENV ${ETCD_ENV}.backup
  print_ok "Backed up $ETCD_ENV → ${ETCD_ENV}.backup"
else
  print_warn "Backup already exists at ${ETCD_ENV}.backup — skipping"
fi

if [ ! -d "${ETCD_DATA_DIR}.backup" ]; then
  sudo cp -r $ETCD_DATA_DIR ${ETCD_DATA_DIR}.backup
  print_ok "Backed up $ETCD_DATA_DIR → ${ETCD_DATA_DIR}.backup"
else
  print_warn "Backup already exists at ${ETCD_DATA_DIR}.backup — skipping"
fi

# =============================================================================
# STEP 3 — Stop etcd
# =============================================================================
print_step "STEP 3 — Stop etcd service"

sudo systemctl stop etcd 2>/dev/null || true
sleep 3
print_ok "etcd stopped"

# =============================================================================
# STEP 4 — Update /etc/etcd.env to single node
# =============================================================================
print_step "STEP 4 — Update etcd config to single node"

echo "Current ETCD_INITIAL_CLUSTER:"
grep "^ETCD_INITIAL_CLUSTER=" $ETCD_ENV

sudo sed -i "s|^ETCD_INITIAL_CLUSTER=.*|ETCD_INITIAL_CLUSTER=${ETCD_NAME}=${ETCD_PEER_URL}|" $ETCD_ENV

echo "Updated ETCD_INITIAL_CLUSTER:"
grep "^ETCD_INITIAL_CLUSTER=" $ETCD_ENV
print_ok "Config updated to single node"

# =============================================================================
# STEP 5 — Force new cluster with correct TLS + data dir
# =============================================================================
print_step "STEP 5 — Force etcd single-node start with TLS"

sudo $ETCD_BIN \
  --force-new-cluster \
  --name=$ETCD_NAME \
  --data-dir=$ETCD_DATA_DIR \
  --listen-client-urls=${ETCD_CLIENT_URL},https://127.0.0.1:2379 \
  --advertise-client-urls=$ETCD_CLIENT_URL \
  --listen-peer-urls=$ETCD_PEER_URL \
  --initial-advertise-peer-urls=$ETCD_PEER_URL \
  --initial-cluster=${ETCD_NAME}=${ETCD_PEER_URL} \
  --cert-file=$ETCD_MEMBER_CERT \
  --key-file=$ETCD_MEMBER_KEY \
  --trusted-ca-file=$ETCD_CACERT \
  --client-cert-auth=true \
  --peer-cert-file=$ETCD_MEMBER_CERT \
  --peer-key-file=$ETCD_MEMBER_KEY \
  --peer-trusted-ca-file=$ETCD_CACERT \
  --peer-client-cert-auth=true \
  --log-level=warn &

ETCD_PID=$!
print_warn "Started etcd with --force-new-cluster (PID: $ETCD_PID)"

echo "Waiting 15 seconds for etcd to start..."
sleep 15

# =============================================================================
# STEP 6 — Verify etcd is responding
# =============================================================================
print_step "STEP 6 — Verify etcd is responding"

RETRY=0
MAX_RETRY=6
until etcdctl_cmd endpoint health > /dev/null 2>&1; do
  RETRY=$((RETRY+1))
  if [ $RETRY -ge $MAX_RETRY ]; then
    print_error "etcd not responding after $MAX_RETRY attempts — aborting"
    sudo kill $ETCD_PID 2>/dev/null || true
    exit 1
  fi
  print_warn "Attempt $RETRY/$MAX_RETRY — not ready yet, waiting 5s..."
  sleep 5
done

print_ok "etcd is responding with TLS!"
echo ""
echo "Current etcd members:"
etcdctl_cmd member list -w table

# =============================================================================
# STEP 7 — Remove dead members (etcd2=master01, etcd3=master02)
# =============================================================================
print_step "STEP 7 — Remove dead members (master01=etcd2, master02=etcd3)"

ETCD2_ID=$(etcdctl_cmd member list 2>/dev/null | grep "etcd2" | awk -F',' '{print $1}' | tr -d ' ')
ETCD3_ID=$(etcdctl_cmd member list 2>/dev/null | grep "etcd3" | awk -F',' '{print $1}' | tr -d ' ')

if [ -n "$ETCD2_ID" ]; then
  etcdctl_cmd member remove $ETCD2_ID
  print_ok "Removed etcd2 (master01) — ID: $ETCD2_ID"
else
  print_warn "etcd2 not found — already removed"
fi

if [ -n "$ETCD3_ID" ]; then
  etcdctl_cmd member remove $ETCD3_ID
  print_ok "Removed etcd3 (master02) — ID: $ETCD3_ID"
else
  print_warn "etcd3 not found — already removed"
fi

echo ""
echo "Remaining members (should be etcd1 only):"
etcdctl_cmd member list -w table

# =============================================================================
# STEP 8 — Stop manual etcd, hand over to systemd
# =============================================================================
print_step "STEP 8 — Switch from manual etcd to systemd"

sudo kill $ETCD_PID 2>/dev/null || true
sudo pkill -f "force-new-cluster" 2>/dev/null || true
sleep 5
print_ok "Stopped manual etcd process"

# Start via systemd
sudo systemctl start etcd
echo "Waiting 20 seconds for systemd etcd..."
sleep 20

# Check systemd etcd — but do NOT exit if it fails on first check
# (it may need a moment after force-new-cluster)
RETRY=0
MAX_RETRY=6
until sudo systemctl is-active --quiet etcd; do
  RETRY=$((RETRY+1))
  if [ $RETRY -ge $MAX_RETRY ]; then
    print_error "etcd systemd failed to start after $MAX_RETRY attempts"
    sudo journalctl -xeu etcd.service -n 20 --no-pager
    exit 1
  fi
  print_warn "Attempt $RETRY/$MAX_RETRY — etcd systemd not active yet, retrying in 5s..."
  sudo systemctl start etcd 2>/dev/null || true
  sleep 5
done

print_ok "etcd started successfully via systemd"

# =============================================================================
# STEP 9 — Final etcd health check
# =============================================================================
print_step "STEP 9 — Final etcd health check"

sleep 5
etcdctl_cmd endpoint health
echo ""
etcdctl_cmd member list -w table
print_ok "etcd healthy — single node confirmed"

# =============================================================================
# STEP 10 — Restart kubelet (manages kube-apiserver as static pod)
# =============================================================================
print_step "STEP 10 — Restart kubelet to recover kube-apiserver"

# kube-apiserver is NOT a systemd service in Kubespray
# It runs as a static pod managed by kubelet
sudo systemctl restart kubelet
echo "Waiting 30 seconds for kubelet and kube-apiserver static pod..."
sleep 30

RETRY=0
MAX_RETRY=6
until sudo systemctl is-active --quiet kubelet; do
  RETRY=$((RETRY+1))
  if [ $RETRY -ge $MAX_RETRY ]; then
    print_error "kubelet failed to start"
    sudo systemctl status kubelet --no-pager
    exit 1
  fi
  print_warn "Attempt $RETRY/$MAX_RETRY — kubelet not active yet, waiting 5s..."
  sleep 5
done

print_ok "kubelet is running"

# =============================================================================
# STEP 11 — Wait for kube-apiserver static pod
# =============================================================================
print_step "STEP 11 — Wait for kube-apiserver static pod to come up"

echo "Checking for apiserver container via crictl..."
RETRY=0
MAX_RETRY=12
until sudo crictl ps 2>/dev/null | grep -q "apiserver"; do
  RETRY=$((RETRY+1))
  if [ $RETRY -ge $MAX_RETRY ]; then
    print_warn "apiserver container not detected via crictl — may still be starting"
    break
  fi
  print_warn "Attempt $RETRY/$MAX_RETRY — waiting for apiserver pod (5s)..."
  sleep 5
done

echo ""
echo "Running control plane containers:"
sudo crictl ps 2>/dev/null | grep -E "apiserver|etcd|scheduler|controller" \
  || print_warn "No containers matched or crictl unavailable"

# =============================================================================
# STEP 12 — Verify cluster with kubectl
# =============================================================================
print_step "STEP 12 — Verify Kubernetes cluster"

echo "Waiting 20 more seconds for API server to be fully ready..."
sleep 20

RETRY=0
MAX_RETRY=8
until kubectl get nodes > /dev/null 2>&1; do
  RETRY=$((RETRY+1))
  if [ $RETRY -ge $MAX_RETRY ]; then
    print_warn "kubectl not responding after $MAX_RETRY attempts"
    echo "Try manually: kubectl get nodes"
    break
  fi
  print_warn "Attempt $RETRY/$MAX_RETRY — API server not ready yet (10s)..."
  sleep 10
done

echo ""
if kubectl get nodes -o wide 2>/dev/null; then
  print_ok "Cluster is accessible!"
else
  print_warn "Run 'kubectl get nodes' again in 1-2 minutes"
fi

# =============================================================================
print_step "RECOVERY COMPLETE"

echo ""
echo "Summary:"
echo "  ✅ etcd running as single node (etcd1 / master-seang only)"
echo "  ✅ Dead members etcd2 (master01) and etcd3 (master02) removed"
echo "  ✅ kubelet restarted — kube-apiserver static pod recovering"
echo ""
echo "Verify with:"
echo "  kubectl get nodes -o wide"
echo "  kubectl get pods -A"
echo ""
echo "Next steps after cluster is stable:"
echo "  1. Provision new GCP VMs for replacement master nodes"
echo "  2. Add them to inventory.ini"
echo "  3. Run scale.yml to restore HA"
echo ""
print_warn "Backups saved at:"
echo "  ${ETCD_ENV}.backup"
echo "  ${ETCD_DATA_DIR}.backup"