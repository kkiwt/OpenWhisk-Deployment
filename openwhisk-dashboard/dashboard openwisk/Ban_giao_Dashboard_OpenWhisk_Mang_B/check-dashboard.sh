#!/usr/bin/env bash
# Safe read-only Dashboard API smoke test. Does not change OpenWhisk or post fake events.
set -euo pipefail
BASE_URL="${1:-http://127.0.0.1:9000}"
BASE_URL="${BASE_URL%/}"
command -v curl >/dev/null || { echo 'Can cai curl de chay test'; exit 2; }
command -v python3 >/dev/null || { echo 'Can python3'; exit 2; }
python3 - "$BASE_URL" <<'PYT'
import json, subprocess, sys
base=sys.argv[1]
for path in ('/health','/api/stats?window=60','/api/recent?limit=1'):
    p=subprocess.run(['curl','--connect-timeout','3','--max-time','10','-fsS',base+path],capture_output=True,text=True)
    if p.returncode:
        print('FAIL',path,p.stderr.strip()); sys.exit(1)
    try: obj=json.loads(p.stdout)
    except json.JSONDecodeError:
        print('FAIL',path,'response not JSON');sys.exit(1)
    if path=='/health': ok=obj.get('ok') is True
    elif path.startswith('/api/stats'): ok='overview' in obj and 'clusters' in obj
    else:ok=isinstance(obj.get('items'),list)
    print(('PASS' if ok else 'FAIL'),path)
    if not ok: sys.exit(1)
print('OK: smoke test GET, khong tao du lieu mau')
PYT
