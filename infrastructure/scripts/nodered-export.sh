#!/usr/bin/env bash
# Snapshot the running Node-RED flows into git (sanitized) and regenerate the
# seed ConfigMap. Run after editing flows in the GUI so they survive teardown.
#
#   make nodered_export
set -euo pipefail

KUBECTL=${KUBECTL:-kubectl}
NS=iot-system
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEED="$ROOT/apps/nodered/flows.json"
CM="$ROOT/infrastructure/manifests/nodered/flows-configmap.yaml"

POD="$($KUBECTL get pod -n "$NS" -l app=nodered -o jsonpath='{.items[0].metadata.name}')"
echo "Exporting flows from $POD ..."
$KUBECTL exec -n "$NS" "$POD" -c nodered -- cat /data/flows.json > "$SEED.tmp"

# Blank inline DB passwords so credentials never land in git.
python3 - "$SEED.tmp" "$SEED" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
for n in d:
    if n.get('type') == 'postgreSQLConfig' and n.get('passwordFieldType') == 'str':
        n['password'] = ''
json.dump(d, open(dst, 'w'), indent=4)
open(dst, 'a').write('\n')
PY
rm -f "$SEED.tmp"

$KUBECTL create configmap nodered-flows -n "$NS" \
  --from-file=flows.json="$SEED" --dry-run=client -o yaml > "$CM"

echo "Updated:"
echo "  $SEED"
echo "  $CM"
echo "Commit these to persist the flows. (DB password is blanked — re-enter it in the GUI after a fresh setup.)"
