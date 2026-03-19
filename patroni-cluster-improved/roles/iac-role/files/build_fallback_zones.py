import json, re

with open('/tmp/ansible_machines.json')    as f: machines  = {m['name']: m for m in json.load(f)}
with open('/tmp/ansible_new_relocate.json')as f: failures  = json.load(f)
with open('/tmp/ansible_allzones.json')    as f: all_zones = json.load(f)

result = []
for f in failures:
    name          = f['name']
    failed_region = re.sub(r'-[a-z]$', '', machines[name]['zone'])
    diff_zones    = [z for z in all_zones if not z.startswith(failed_region + '-')]
    new_zone      = diff_zones[0] if diff_zones else all_zones[0]
    spec          = dict(machines[name])
    spec['zone']  = new_zone
    result.append(spec)

print(json.dumps(result))
