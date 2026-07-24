# Test suites

BrainlessLab separates tests by the kind of proof they provide. The default
gate is deliberately small. It checks interfaces, configuration, registries,
documentation contracts, and package quality without running the full
research stack.

Set `BRAINLESSLAB_TEST_SUITE` before `Pkg.test()`:

```bash
# Default: fast contract and package checks.
julia --project=. -e 'using Pkg; Pkg.test()'

# Runtime behaviours and component integration.
BRAINLESSLAB_TEST_SUITE=runtime julia --project=. -e 'using Pkg; Pkg.test()'

# Repeated-operation orchestration, serialisation, records, and seed pairing.
BRAINLESSLAB_TEST_SUITE=operations julia --project=. -e 'using Pkg; Pkg.test()'

# Immutable fixture integrity, numerical parity, and score calibration.
BRAINLESSLAB_TEST_SUITE=oracle julia --project=. -e 'using Pkg; Pkg.test()'

# Retained dyad and replay compatibility only.
BRAINLESSLAB_TEST_SUITE=legacy julia --project=. -e 'using Pkg; Pkg.test()'

# Every non-visual suite.
BRAINLESSLAB_TEST_SUITE=all julia --project=. -e 'using Pkg; Pkg.test()'
```

`test/suites.jl` assigns each top-level executable test file to exactly one
suite. The loader stops before testing if a file is missing, duplicated, or
declared in two places.

The visual files are declared separately because they require Makie and
produce image or animation artefacts. They are not included in `all`. Run
them through the dedicated visual environment and gate.

Scientific fixtures are immutable inputs. `SCIENTIFIC_FIXTURES.sha256` seals
every file below `test/fixtures/`, including files in nested directories.
Manifest paths are forward-slash relative paths from `test/fixtures/`. They
must not be absolute, contain `.` or `..` components, use backslashes, or
name the manifest itself. The oracle suite rejects missing files, unlisted
files, symlinks, duplicate paths, invalid digests, and changed contents.
Tests must not regenerate a missing or changed fixture.

CI stores a success marker only for an exact checked-in input set and hosted
runner image. The key includes the runner image version and architecture,
resolved Julia version, suite name, workflow, package environment, source,
test loader, suite declaration, test utilities, and the files declared for
that suite. External inputs are also suite-specific: Core owns public
documentation and catalogue paths, Runtime owns the examples it includes,
Operations owns plans and research protocols, Oracle owns sealed fixtures and
calibration tools, and Legacy owns only its assigned compatibility tests and
their shared source. A documentation-only change does not invalidate Runtime,
Oracle, or Legacy.

Pinned suites check their proof before package restoration. The manifest-free,
visual, and project-template jobs first resolve their generated environment and
add the generated manifest's SHA-256 digest to the proof key. An exact hit in
the manifest-free and visual jobs skips the remaining installation,
precompilation, and test body but does not skip live resolution. In the tool
job, the root package is still instantiated and the research policy checks
still run. The proof hit skips package precompilation, template installation,
plan smoke checks, and template execution. Dependency and compiled-code caches
remain separate from proof markers.

The tool smoke gate always regenerates `research/catalogue.json` and compares
it byte-for-byte with the committed catalogue, even when the ordinary tool
proof is cached. It also always validates each accepted contribution against
the full repository history. Append-only validation uses the pull request base
for a pull request and the previous commit for a direct push. Scheduled and
manually dispatched runs omit the base comparison.
