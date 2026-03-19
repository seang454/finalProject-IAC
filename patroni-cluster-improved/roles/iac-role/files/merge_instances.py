import json, sys

# Load each source — all written by copy tasks before this script runs
def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return []

existing_results   = load('/tmp/ansible_existing_details.json')
new_results        = load('/tmp/ansible_new_instance_results.json')
retry_results      = load('/tmp/ansible_retry_instance_results.json')

all_instances = []
seen = set()

# 1. Already-running/started instances — from `gcloud instances describe` stdout
for r in existing_results:
    if r.get('rc', 1) != 0:
        continue
    stdout = r.get('stdout', '').strip()
    if not stdout:
        continue
    try:
        inst = json.loads(stdout)
        name = inst.get('name', '')
        if name and name not in seen:
            seen.add(name)
            all_instances.append(inst)
    except Exception:
        pass

# 2. Newly created instances — from google.cloud.gcp_compute_instance module
#    The module result has instance fields at the top level
for r in new_results:
    if r.get('failed', True):
        continue
    name = r.get('name', '')
    if name and name not in seen:
        seen.add(name)
        all_instances.append(r)

# 3. Retry instances (exhausted zone fallback)
for r in retry_results:
    if r.get('failed', True):
        continue
    name = r.get('name', '')
    if name and name not in seen:
        seen.add(name)
        all_instances.append(r)

print(json.dumps(all_instances))
