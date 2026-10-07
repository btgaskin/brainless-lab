These stubs describe the host boundary used from Quadrants 1.3.3. Pyright uses
them only for static checking; Python and Quadrants retain the real, live
annotations and compiled kernels.

The released package's annotations omit `fastcache`, ndarray shape and host
transfers, and the native runtime namespace. The local declarations retain
kernel callable signatures and frozen dataclass fields, so incorrect host
arguments and missing bundle fields still produce errors. DSL scalar
expressions are dynamic and use `Any`. Integer rank and dtype annotations are
runtime metadata, not Python generic type parameters. The model/task contract
tests and strict backend qualification check those values.

The three legacy `qd.template()` parameter annotations need a line-specific
`reportInvalidTypeForm` exception because call expressions are valid in this
DSL. They do not justify disabling host typing errors or an entire file. Prefer
typed frozen bundles for new kernels.

Run `uv run pyright` from the checkout after `uv sync`. The configuration finds
the checkout's `.venv`; no machine-specific interpreter path is checked in.
