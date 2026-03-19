import json, re

with open('/tmp/ansible_start_results.json') as f:
    results = json.load(f)

started_ok         = []
relocate_failures  = []
not_found_failures = []
transient_failures = []
fatal_failures     = []

RELOCATE  = re.compile(r'ZONE_RESOURCE_POOL_EXHAUSTED|QUOTA_EXCEEDED|ZONE_UNAVAILABLE|ZONE_INACTIVE|RESOURCE_UNAVAILABLE|PREEMPTED')
NOT_FOUND = re.compile(r'RESOURCE_NOT_FOUND|was not found|does not exist')
TRANSIENT = re.compile(r'(?i)500|Internal error|deadline exceeded|connection reset|timed out|temporarily unavailable')
FATAL     = re.compile(r'PERMISSION_DENIED|UNAUTHENTICATED|INVALID_ARGUMENT|active account')

for r in results:
    name   = r.get('item', '')
    rc     = r.get('rc', 0)
    stderr = r.get('stderr', '')

    if rc == 0:
        started_ok.append(name)
    elif FATAL.search(stderr):
        fatal_failures.append({'name': name, 'stderr': stderr})
    elif RELOCATE.search(stderr):
        relocate_failures.append({'name': name, 'stderr': stderr})
    elif NOT_FOUND.search(stderr):
        not_found_failures.append({'name': name, 'stderr': stderr})
    elif TRANSIENT.search(stderr):
        transient_failures.append({'name': name, 'stderr': stderr})
    else:
        relocate_failures.append({'name': name, 'stderr': stderr})

print(json.dumps({
    'started_ok':         started_ok,
    'relocate_failures':  relocate_failures,
    'not_found_failures': not_found_failures,
    'transient_failures': transient_failures,
    'fatal_failures':     fatal_failures,
}))
