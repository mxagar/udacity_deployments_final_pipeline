#!/usr/bin/env bash
set -euo pipefail
image="${1:?Usage: bash scripts/smoke-test.sh IMAGE}"
container_id="$(docker run --detach --read-only --tmpfs /tmp:rw,nosuid,size=64m \
  --cap-drop ALL --security-opt no-new-privileges "$image")"
cleanup() {
  if [[ "${smoke_passed:-0}" != 1 ]]; then docker logs "$container_id" >&2 || true; fi
  docker rm --force "$container_id" >/dev/null
}
trap cleanup EXIT
# Check HTTP inside the container: no host ports or external endpoint needed.
docker exec "$container_id" python -c '
import time
import urllib.error
import urllib.request

for attempt in range(30):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8080/", timeout=2) as response:
            body = response.read().decode()
            assert response.status == 200
            assert body == "Hello, World from Flask!\n", body
        break
    except (urllib.error.URLError, TimeoutError):
        time.sleep(1)
else:
    raise SystemExit("Application did not become ready")
'
# Verify the Docker allowlist kept local credentials out of the image.
docker exec "$container_id" python -c '
from pathlib import Path
import sys
assert {path.name for path in Path("/app").iterdir()} == {"app.py"}
assert sys.prefix == "/opt/venv", sys.prefix
'
smoke_passed=1
printf '%s\n' "Container HTTP smoke test passed"
