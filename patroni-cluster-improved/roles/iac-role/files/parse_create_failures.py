import json, re

with open('/tmp/ansible_create_results.json') as f:
    results = json.load(f)
with open('/tmp/ansible_allzones.json') as f:
    all_zones = json.load(f)

RELOCATE = re.compile(r'ZONE_RESOURCE_POOL_EXHAUSTED|QUOTA_EXCEEDED|ZONE_UNAVAILABLE|ZONE_INACTIVE|RESOURCE_UNAVAILABLE')
FATAL    = re.compile(r'PERMISSION_DENIED|UNAUTHENTICATED|INVALID_ARGUMENT|active account')

exhausted = []
fatal     = []

for r in results:
    if not r.get('failed'):
        continue
    msg  = r.get('msg', '')
    item = r.get('item', {})
    spec = item.get('item', {}) if isinstance(item, dict) else {}
    name = spec.get('name', '')
    zone = spec.get('zone', '')

    if not name:
        continue

    if FATAL.search(msg):
        fatal.append({'name': name, 'zone': zone, 'msg': msg})
    elif RELOCATE.search(msg):
        failed_region = re.sub(r'-[a-z]$', '', zone)
        diff_zones    = [z for z in all_zones if not z.startswith(failed_region + '-')]
        new_zone      = diff_zones[0] if diff_zones else all_zones[0]
        exhausted.append({'name': name, 'old_zone': zone, 'new_zone': new_zone, 'msg': msg})

print(json.dumps({'exhausted': exhausted, 'fatal': fatal}))
