import json, sys

with open('/tmp/ansible_discover_results.json') as f:
    results = json.load(f)

running  = []
stopped  = []
new      = []
zone_map = {}

for r in results:
    name   = r['item']['name']
    stdout = r.get('stdout', '').strip()
    rc     = r.get('rc', 0)
    stderr = r.get('stderr', '')

    if 'You do not currently have an active account' in stderr or \
       'PERMISSION_DENIED' in stderr or 'UNAUTHENTICATED' in stderr:
        print(json.dumps({'auth_error': stderr}))
        sys.exit(1)

    if rc != 0 or not stdout or stdout in ('[]', 'null'):
        new.append(name)
        continue

    try:
        instances = json.loads(stdout)
    except Exception:
        new.append(name)
        continue

    if not instances:
        new.append(name)
        continue

    inst   = instances[0]
    status = inst.get('status', '')
    zone   = inst.get('zone', '').split('/')[-1]
    zone_map[name] = zone

    if status in ('RUNNING', 'STAGING'):
        running.append(name)
    elif status in ('TERMINATED', 'SUSPENDED'):
        stopped.append(name)
    else:
        stopped.append(name)

print(json.dumps({
    'running_instances': running,
    'stopped_instances': stopped,
    'new_instances':     new,
    'actual_zone_map':   zone_map,
}))
