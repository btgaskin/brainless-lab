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

# Compatibility surfaces retained while older runners are retired or replaced.
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
every file under `test/fixtures/`. The oracle suite checks both manifest
coverage and file contents. Tests must not regenerate a missing or changed
fixture.

CI stores a success marker only for an exact suite input set: operating
system, resolved Julia version, suite name, workflow, environments, source,
tests, plans, configuration, and examples. A changed input produces a new
key and runs the suite again. Dependency caches remain separate from these
proof markers.
