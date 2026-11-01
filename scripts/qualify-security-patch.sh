#!/usr/bin/env bash
# Qualify an installed wheel without provider access. Linux network namespaces required.
set -euo pipefail

if [[ $# != 1 || $1 == --help ]]; then
    echo "Usage: bash scripts/qualify-security-patch.sh NEW_ARTIFACT_DIRECTORY"
    echo "Builds wheel, records provenance, runs offline tests with warnings as errors."
    [[ ${1:-} == --help ]] && exit 0
    exit 2
fi
for tool in uv uvx unshare ip python3; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 2; }
done
repo=$(cd "$(dirname "$0")/.." && pwd)
source_head=$(git -C "$repo" rev-parse HEAD)
if [[ -n $(git -C "$repo" status --porcelain) ]]; then
    echo "Qualification requires clean committed source, including test/helper inputs" >&2
    exit 2
fi
mkdir -p "$(dirname "$1")"
mkdir "$1" # Refuse to overwrite earlier evidence.
artifacts=$(cd "$1" && pwd)
mkdir "$artifacts/runner" "$artifacts/config"
(cd "$repo" && uv build --wheel --out-dir "$artifacts/wheels") >"$artifacts/build.log" 2>&1
shopt -s nullglob
wheels=("$artifacts"/wheels/*.whl)
[[ ${#wheels[@]} == 1 ]] || { echo "Expected exactly one wheel" >&2; exit 2; }
wheel=${wheels[0]}
python3 - "$repo" "$wheel" "$artifacts" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

repo, wheel, artifacts = map(Path, sys.argv[1:])
with zipfile.ZipFile(wheel) as archive:
    metadata = next(name for name in archive.namelist() if name.endswith('.dist-info/WHEEL'))
    generator = archive.read(metadata).decode()
receipt = {
    "source_head": subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
    "source_status": subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True),
    "source_diff_sha256": hashlib.sha256(subprocess.check_output(['git', '-C', str(repo), 'diff', 'HEAD'])).hexdigest(),
    "wheel_sha256": hashlib.sha256(wheel.read_bytes()).hexdigest(),
    "wheel_metadata": generator,
    "uv": subprocess.check_output(['uv', '--version'], text=True).strip(),
}
(artifacts / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
cat >"$artifacts/qualification_receipt.py" <<'PY'
import importlib.metadata
import json
import os
from pathlib import Path

def pytest_sessionfinish(session, exitstatus):
    packages = sorted(({'name': d.metadata['Name'], 'version': d.version,
                        'direct_url': d.read_text('direct_url.json')}
                       for d in importlib.metadata.distributions()), key=lambda p: p['name'].lower())
    receipt = {'exit_status': int(exitstatus), 'packages': packages}
    (Path(os.environ['SPARKLES_QUALIFICATION_ARTIFACTS']) / 'test-receipt.json').write_text(
        json.dumps(receipt, indent=2) + '\n')
PY
test_command=(uvx --python "${SPARKLES_QUALIFICATION_PYTHON:-/usr/bin/python3.12}"
    --with "$wheel" --with 'pypdf>=6,<7' --with pytest-mock --with pytest-asyncio
    --with pytest-cov --with pyOpenSSL --from pytest pytest)
(cd "$artifacts/runner" && env PYTEST_ADDOPTS= "${test_command[@]}" --version) >"$artifacts/test-bootstrap.log" 2>&1
cd "$artifacts/runner"
if unshare --net /bin/sh -c 'ip link set lo up && exec "$@"' sh \
    env PYTEST_ADDOPTS= VAST_API_KEY=qualification-no-provider-access XDG_CONFIG_HOME="$artifacts/config" \
    PYTHONPATH="$artifacts" SPARKLES_QUALIFICATION_ARTIFACTS="$artifacts" \
    "${test_command[@]:0:1}" --offline "${test_command[@]:1}" -W error \
    -p qualification_receipt -c "$repo/pyproject.toml" --import-mode=importlib \
    "$repo/tests" --ignore="$repo/tests/pip_install" --ignore="$repo/tests/live" \
    --ignore="$repo/tests/integration" --basetemp="$artifacts/tests" \
    --junitxml="$artifacts/tests.xml" >"$artifacts/tests.log" 2>&1; then
    if [[ $(git -C "$repo" rev-parse HEAD) != "$source_head" || -n $(git -C "$repo" status --porcelain) ]]; then
        echo "Source changed during qualification; evidence cannot certify this checkout" >&2
        exit 2
    fi
    tail -n 4 "$artifacts/tests.log"
    echo "Qualification passed: $artifacts"
else
    result=$?
    tail -n 30 "$artifacts/tests.log"
    exit "$result"
fi
