# Vast SDK Tests

## Configuration

### API Key

Tests that hit the Vast API require an API key. Resolved in order:

1. `VAST_API_KEY` environment variable
2. `$XDG_CONFIG_HOME/vastai/vast_api_key` (typically `~/.config/vastai/vast_api_key`)
3. `~/.vast_api_key` (legacy)

### Server

By default, tests run against `https://console.vast.ai`. Override with:

```
VAST_SERVER=https://alpha.vast.ai pytest tests/
```

### Serverless Instance

Serverless tests target the `prod` autoscaler by default. Override with:

```
VAST_SERVERLESS_INSTANCE=alpha pytest tests/
```

### Template Hash

Serverless integration tests use the vLLM template by default
(`490c0ed717a7da3bc5e2677a80f9c4c2`). Override with:

```
VAST_TEST_TEMPLATE_HASH=<hash> pytest tests/
```

## Running Tests

```bash
# All tests
pytest tests/

# Only unit tests (no API calls)
pytest tests/test_data_objects.py

# Only integration tests (currently errors at setup: see the note below)
pytest tests/ -m integration

# Serverless tests (creates real resources — costs money; same setup error)
pytest tests/ -m serverless
```

`tests/pyproject.toml` sets `addopts = "-m 'not live and not integration'"`, so a
plain `pytest tests/` deselects `test_search.py` and `test_serverless_lifecycle.py`.
Passing `-m integration` or `-m serverless` selects them, and they fail at setup
with `fixture 'sync_client' not found` (or `serverless_client`, `managed_endpoint`,
...): the client fixtures they request are not defined in `conftest.py` yet (see
`conftest.py` below). CI (`.github/workflows/vast-sdk-testing.yml`) never runs
these two files.

## Test Files

### `test_data_objects.py` — Unit tests for data objects

Pure unit tests with no API calls. Tests Query, Column, EndpointConfig,
WorkergroupConfig, DeploymentConfig, Offer, and their serialization.

**Setup/teardown:** None.

### `test_search.py` — Search API integration tests

Tests SyncClient.search() and AsyncClient.search() against the live API.
Read-only — no resources created or modified.

**Setup/teardown:** None.

### `test_serverless_lifecycle.py` — Serverless endpoint lifecycle tests

Tests the full serverless flow: create endpoint, add workergroup, send
request, delete workergroup, delete endpoint. Uses the vLLM template.

**Setup/teardown:**
- **Setup:** Creates an endpoint (`POST /api/v0/endptjobs/`) and a
  workergroup (`POST /api/v0/workergroups/`) with the configured template
  hash. These are created once per test session as a session-scoped fixture.
- **Teardown:** Deletes the workergroup (`DELETE /api/v0/workergroups/{id}/`)
  and endpoint (`DELETE /api/v0/endptjobs/{id}/`) in `finally` blocks.
  If teardown fails, resource IDs are printed for manual cleanup.

**Cost note:** Creating a workergroup provisions GPU instances via the
autoscaler. Tests in this file will incur real costs.

### `conftest.py` — Shared fixtures

Defines `api_key` (reads `VAST_API_KEY`, skips the test when it is unset) and
`live_client` (a real `VastClient` built from `api_key`), plus mock fixtures for
the unit tests.

**Not defined anywhere yet:** `vast_server`, `serverless_instance`,
`template_hash`, `sync_client`, `async_client`, `serverless_client`,
`_serverless_loop` and `managed_endpoint`. `test_search.py` and
`test_serverless_lifecycle.py` request them, so those two files cannot run until
the fixtures are written (behind a `VAST_API_KEY` skip). Until then the
`VAST_SERVER`, `VAST_SERVERLESS_INSTANCE` and `VAST_TEST_TEMPLATE_HASH` overrides
above are not read by any test code, and `api_key` reads only the `VAST_API_KEY`
environment variable (not the config-file fallbacks).
