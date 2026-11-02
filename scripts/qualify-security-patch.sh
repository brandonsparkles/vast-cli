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
# Everything that can change what the suite runs or what the wheel contains. Prints nothing when the source is
# clean. var/agent-audits is the untracked triage index of this checkout, not source, so status skips it.
# Ignored files under tests, scripts, vastai and vastai_sdk (.gitignore matches *egg*, local, env/, venv/) are
# invisible to git status, yet pytest still collects them and uv build still packages them, so they count too;
# bytecode caches are the only ignored files allowed.
source_state() {
    local ignored
    git -C "$repo" status --porcelain -- . ':(exclude)var/agent-audits' || return 2
    ignored=$(git -C "$repo" ls-files --others --ignored --exclude-standard -- tests scripts vastai vastai_sdk) || return 2
    printf '%s\n' "$ignored" | grep -Ev '^$|(^|/)__pycache__/|\.py[co]$' || true
}
state=$(source_state) || { echo "Cannot read source state of $repo" >&2; exit 2; }
if [[ -n $state ]]; then
    echo "Qualification requires clean committed source, including test/helper inputs" >&2
    printf '%s\n' "$state" | head -n 20 >&2
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
receipt_state=$(source_state) || { echo "Cannot read source state of $repo" >&2; exit 2; }
python3 - "$repo" "$wheel" "$artifacts" "$receipt_state" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

repo, wheel, artifacts = map(Path, sys.argv[1:4])
source_state = sys.argv[4]
with zipfile.ZipFile(wheel) as archive:
    metadata = next(name for name in archive.namelist() if name.endswith('.dist-info/WHEEL'))
    generator = archive.read(metadata).decode()
receipt = {
    "source_head": subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
    "source_status": source_state,
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
cat >"$artifacts/qualification_collect.py" <<'PY'
import os
from pathlib import Path

def pytest_collection_finish(session):
    (Path(os.environ['SPARKLES_QUALIFICATION_ARTIFACTS']) / 'collected-count.txt').write_text(
        f'{len(session.items)}\n')
PY
test_command=(uvx --python "${SPARKLES_QUALIFICATION_PYTHON:-/usr/bin/python3.12}"
    --with "$wheel" --with 'pypdf>=6,<7' --with pytest-mock --with pytest-asyncio
    --with pytest-cov --with pyOpenSSL --from pytest pytest)
# Collection must come from the command line and the tracked tree only: an inherited PYTEST_PLUGINS module could
# narrow it, and PYTEST_DISABLE_PLUGIN_AUTOLOAD would drop the pytest-* plugins installed above.
pytest_env=(env -u PYTEST_PLUGINS -u PYTEST_DISABLE_PLUGIN_AUTOLOAD PYTEST_ADDOPTS=)
(cd "$artifacts/runner" && "${pytest_env[@]}" "${test_command[@]}" --version) >"$artifacts/test-bootstrap.log" 2>&1
cd "$artifacts/runner"
suite_args=(-W error -c "$repo/pyproject.toml" --import-mode=importlib
    "$repo/tests" --ignore="$repo/tests/pip_install" --ignore="$repo/tests/live"
    --ignore="$repo/tests/integration")
run_offline_pytest() {
    unshare --net /bin/sh -c 'ip link set lo up && exec "$@"' sh \
        "${pytest_env[@]}" VAST_API_KEY=qualification-no-provider-access XDG_CONFIG_HOME="$artifacts/config" \
        PYTHONPATH="$artifacts" SPARKLES_QUALIFICATION_ARTIFACTS="$artifacts" \
        "${test_command[@]:0:1}" --offline "${test_command[@]:1}" "$@"
}
# Baseline for the JUnit check below: item count from a collect-only run in the same cleaned environment on the same
# tree. The plugin writes it, so the count does not depend on the verbosity that pyproject addopts sets.
result=0
run_offline_pytest "${suite_args[@]}" --collect-only -p qualification_collect >"$artifacts/collect.log" 2>&1 || result=$?
if [[ $result != 0 ]]; then
    tail -n 30 "$artifacts/collect.log"
    exit "$result"
fi
collected=$(cat "$artifacts/collected-count.txt" 2>/dev/null || true)
if [[ ! $collected =~ ^[0-9]+$ || $collected == 0 ]]; then
    echo "Could not read a positive collected-test count ($artifacts/collected-count.txt)" >&2
    tail -n 5 "$artifacts/collect.log" >&2
    exit 2
fi
if run_offline_pytest "${suite_args[@]}" -p qualification_receipt --basetemp="$artifacts/tests" \
    --junitxml="$artifacts/tests.xml" >"$artifacts/tests.log" 2>&1; then
    final_state=$(source_state) || { echo "Cannot read source state of $repo" >&2; exit 2; }
    if [[ $(git -C "$repo" rev-parse HEAD) != "$source_head" || -n $final_state ]]; then
        echo "Source changed during qualification; evidence cannot certify this checkout" >&2
        exit 2
    fi
    # Exit 0 only proves what ran passed. The retained JUnit file (skips included) must cover everything collected.
    junit_tests=$(python3 - "$artifacts/tests.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
suites = [root] if root.tag == 'testsuite' else root.findall('testsuite')
print(sum(int(suite.get('tests', 0)) for suite in suites))
PY
    ) || { echo "Cannot read test count from $artifacts/tests.xml" >&2; exit 2; }
    if (( junit_tests < collected )); then
        echo "tests.xml reports $junit_tests tests but $collected were collected; the run was narrowed" >&2
        exit 2
    fi
    tail -n 4 "$artifacts/tests.log"
    echo "Tests: $junit_tests executed, $collected collected"
    echo "Qualification passed: $artifacts"
else
    result=$?
    tail -n 30 "$artifacts/tests.log"
    exit "$result"
fi
