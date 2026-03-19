import re, json, sys

vars_file = sys.argv[1]

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

with open(vars_file, 'r') as f:
    content = f.read()

pg_zones      = []
haproxy_zones = []
for name, zone in zone_map.items():
    if name.startswith('pg-node') and zone not in pg_zones:
        pg_zones.append(zone)
    elif name.startswith('ha-proxy') and zone not in haproxy_zones:
        haproxy_zones.append(zone)

def replace_yaml_list(content, key, new_values):
    pattern   = r'(' + re.escape(key) + r':\s*\n)((?:\s+- .*\n)*)'
    new_block = key + ':\n' + ''.join('  - "' + v + '"\n' for v in new_values)
    return re.sub(pattern, new_block, content)

def replace_scalar(content, key, new_value):
    pattern = r'^(' + re.escape(key) + r':\s*).*$'
    return re.sub(pattern, r'\g<1>' + str(new_value), content, flags=re.MULTILINE)

if pg_zones:
    content = replace_yaml_list(content, 'pg_node_zones', pg_zones)
    content = replace_scalar(content, 'pg_node_count',
                len([n for n in zone_map if n.startswith('pg-node')]))
    print('pg_node_zones  -> ' + str(pg_zones))

if haproxy_zones:
    content = replace_yaml_list(content, 'haproxy_node_zones', haproxy_zones)
    content = replace_scalar(content, 'haproxy_node_count',
                len([n for n in zone_map if n.startswith('ha-proxy')]))
    print('haproxy_node_zones -> ' + str(haproxy_zones))

with open(vars_file, 'w') as f:
    f.write(content)

print('Done — defaults/main.yml synced with actual running zones.')
