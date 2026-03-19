import json

with open('/tmp/ansible_final_instances.json') as f:
    results = json.load(f)

zone_map = {}
for r in results:
    if r.get('rc', 1) != 0:
        continue
    stdout = r.get('stdout', '').strip()
    if not stdout or stdout in ('[]', 'null'):
        continue
    try:
        instances = json.loads(stdout)
        if instances:
            inst = instances[0]
            zone_map[inst['name']] = inst['zone'].split('/')[-1]
    except Exception:
        pass

print(json.dumps(zone_map))
