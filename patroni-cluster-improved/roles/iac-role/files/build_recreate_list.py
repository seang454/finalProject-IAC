import json, re

with open('/tmp/ansible_machines.json')  as f: machines  = json.load(f)
with open('/tmp/ansible_relocate.json')  as f: relocate  = json.load(f)
with open('/tmp/ansible_notfound.json')  as f: notfound  = json.load(f)
with open('/tmp/ansible_allzones.json')  as f: all_zones = json.load(f)
with open('/tmp/ansible_zonemap.json')   as f: zone_map  = json.load(f)

machines_by_name = {m['name']: m for m in machines}
result = []

for r in relocate:
    name          = r['name']
    failed_region = re.sub(r'-[a-z]$', '', zone_map.get(name, ''))
    diff_zones    = [z for z in all_zones if not z.startswith(failed_region + '-')]
    new_zone      = diff_zones[0] if diff_zones else all_zones[0]
    spec          = dict(machines_by_name[name])
    spec['zone']  = new_zone
    spec['_reason'] = 'relocate'
    result.append(spec)

for r in notfound:
    name = r['name']
    spec = dict(machines_by_name[name])
    spec['_reason'] = 'not_found'
    result.append(spec)

print(json.dumps(result))
