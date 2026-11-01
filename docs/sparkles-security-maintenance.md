# Sparkles Vast CLI security maintenance

**Keywords:** Vast CLI, vastai, managed fork, security update, Pillow 13, cryptography 50, invoice PDF, qualification, immutable provenance

This maintained fork starts at upstream `v1.10.0`, commit
`a357b331fdebc4c137dd11be853e1290bdc27c9a`. It retains the upstream MIT
license and package version `1.10.0`. It is patched Sparkles source, not the
official PyPI wheel. Installers must pin a full fork Git commit, retain PEP 610
`direct_url.json`, and record the wheel hash and complete resolved dependency
graph. A package version alone does not identify this build.

The patch permits cryptography 50 and Pillow 13, raises Python's minimum to
3.11, and retains Borb 2.1.25. Borb 3 is a separate migration. Invoice repairs
use Borb 2's public document, table and margin APIs; flatten transparent logos
onto the invoice's white background; preserve exact cents through Decimal
arithmetic; and retain useful dependency import errors. API key files close
through context managers. Production archive behavior remains gzip; stale
tests now assert that existing contract.

The new PDF suite checks empty invoices, first-page and later-page boundaries,
embedded images, final row text, both output filenames and exact monetary
totals using independent pypdf parsing. Local qualification includes PDF/archive
tests and treats warnings as errors. Both Poetry lockfiles include test-only
dependencies; production installs must omit development dependencies.
Inherited GitHub workflow files stay unchanged for upstream merges; Actions is
disabled on this fork. Local fleet hooks and qualification own validation.

## Qualify a replacement

The Linux helper below automates wheel construction, build/test receipts and
the complete offline suite. Source must be clean and committed; artifact directory must be new. It retains
evidence on failure and never installs or selects the production environment.

```bash
bash scripts/qualify-security-patch.sh /var/lib/sparkles-update/vast-qualification-NEW
```

1. Start with a clean, immutable upstream tag. Compare its metadata and retained
   API behavior with this patch; never assume an unchanged version means an
   unchanged source tree.
2. Refresh both Poetry locks using Poetry 2.5.1. Run `poetry check --lock` in
   the root and `tests` directories. Run the fork's changed Python files through
   Ruff. Build a wheel using the declared Poetry Core backend and record the
   actual build-tool versions and wheel SHA256.
3. Test the installed wheel from an empty working directory with pytest's
   `--import-mode=importlib`, Python 3.12 and `-W error`. Include the complete
   `tests` directory, excluding `tests/pip_install`, `tests/live` and
   `tests/integration`; root pytest defaults also exclude live/integration
   markers. The tests use synthetic credentials. Run with networking disabled
   and loopback enabled on Linux (`unshare --net`, then `ip link set lo up`)
   so qualification cannot allocate provider resources. Retain JUnit output
   and the full test dependency graph.
4. Render synthetic invoice PDFs with Poppler. Inspect an empty invoice, first
   page, page-boundary case and final page of a multipage invoice. Text/image
   parsing alone does not establish correct visual layout.
5. Audit the complete resolved production graph; audit failures and skipped
   packages block selection. Probe CLI help and read-only provider pagination
   as an actual consumer UID. Never rent an instance for an update probe.
6. Before selecting a new runtime, promote and verify the physical Rust burst
   parser that consumes its output. Retain the previous environment and an
   immutable installation receipt; use a new fixed-path environment rather
   than moving a virtualenv with absolute shebangs. Verify installed Git
   provenance, graph, CLI behavior and read-only payload after selection.

This recipe records qualified artifacts and tools. It does not promise
bit-for-bit reproducible wheels.

## Retire the fork patch

Return to an official release when upstream permits an audited clean dependency
graph and its retained CLI, SDK and invoice behavior passes these checks.
Remove only repairs that upstream actually incorporates. Keep the regressions
and immutable provenance checks. Never restore vulnerable exact pins merely
to match upstream metadata.
