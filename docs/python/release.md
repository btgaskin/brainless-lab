# Publish BrainlessLab 0.4.0

Publish this version as an experimental software release. Its software checks do not
promote historical research or establish learning, cognition or biological fidelity.
The [release notes](../../CHANGELOG.md) describe the breaking Python and Quadrants cutover.

## Verify the candidate

Use a clean candidate checkout and retain the exact Git revision. Preserve unrelated
working files. Build the distribution before running the installed-wheel gate:

```bash
uv sync --locked --group dev
uv build
BRAINLESSLAB_TEST_WHEEL=dist/brainlesslab-0.4.0-py3-none-any.whl uv run pytest
uv run ruff check python
uv run ruff format --check python
uv run pyright
git diff --check
cd site
bun install --frozen-lockfile
bun test
bun run typecheck
bun run build
```

Run the first-simulation plan and inspect the printed record. Success requires
`complete: true` and `checksums_valid: true`. Check the homepage acknowledgements,
the documentation navigation and the task illustrations in a browser.
Check the landing page and start page at desktop and phone widths. Confirm all ten
task families are reachable, historical pages remain labelled, the empty accepted-run
catalogue is explicit, and old page links and section anchors still resolve.

Keep the local CPU result separate from the retained Metal qualification receipts.
The Windows installed-wheel test uses `Scripts/python.exe`; POSIX uses `bin/python`.
A source-path correction alone does not qualify Windows execution.

## Complete the publication gates

After publishing the candidate source, wait for the `Python CPU and site` workflow
at that exact revision. Require successful Ubuntu x64, Windows x64, macOS arm64
and site jobs. Record the run URL and revision before reporting those platforms
as qualified. A local check or a configured workflow is insufficient.

The production workflow waits for successful CI on `main` and checks out its exact
tested revision. Confirm the Cloudflare deployment belongs to that revision.
Check the deployed homepage, first-simulation guide, platform limits and attribution.
Verify both the immutable deployment URL and the public site.

Once CI and deployment have passed, change the 0.4.0 changelog heading from
`release candidate` to its publication date and verify the final revision.
Create the `v0.4.0` tag and release from the approved revision, retaining the wheel,
source distribution and their SHA-256 checksums. Do not move an existing release tag.

Historical sources remain reachable through the version-history links. Accepted
research records, sealed evaluation material and historical fixtures remain unchanged.
Package-registry publication is a separate destination and is not required to publish
the repository and site.
