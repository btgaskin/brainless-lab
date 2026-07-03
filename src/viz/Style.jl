"""
Warm visual identity shared by BrainlessLab visualization surfaces.

These constants are Makie-agnostic RGB float triples. Backends should construct
their own color type with splatting, for example `Makie.RGBf(BL_TEAL...)`.

Semantic mapping:
- accent: teal (`BL_TEAL`)
- source/warn: amber (`BL_AMBER`)
- structure: ink (`BL_INK`, `BL_INKSOFT`)
- surface: paper (`BL_PAPER`)

`BL_CATEGORICAL` is an ordered, fixed set for multi-series plots:
teal, amber, ink-soft, then muted variants. Select by index deliberately; do
not treat it as an automatic cycling palette.
"""

const BL_PAPER = (251 / 255, 250 / 255, 247 / 255)      # #fbfaf7 warm paper
const BL_INK = (36 / 255, 40 / 255, 43 / 255)           # #24282b
const BL_INKSOFT = (82 / 255, 88 / 255, 93 / 255)       # #52585d
const BL_GRID = (222 / 255, 218 / 255, 208 / 255)       # #dedad0
const BL_TEAL = (47 / 255, 111 / 255, 94 / 255)         # #2f6f5e
const BL_TEALSOFT = (101 / 255, 156 / 255, 139 / 255)   # #659c8b
const BL_AMBER = (156 / 255, 107 / 255, 31 / 255)       # #9c6b1f
const BL_AMBERSOFT = (190 / 255, 155 / 255, 91 / 255)   # #be9b5b
const BL_INKMUTED = (130 / 255, 137 / 255, 143 / 255)   # #82898f

const BL_STYLE_SEMANTICS = (
    accent = BL_TEAL,
    source = BL_AMBER,
    warn = BL_AMBER,
    structure = BL_INK,
    surface = BL_PAPER,
)

const BL_CATEGORICAL = (
    BL_TEAL,
    BL_AMBER,
    BL_INKSOFT,
    BL_TEALSOFT,
    BL_AMBERSOFT,
    BL_INKMUTED,
)

const BL_SEQUENTIAL = (BL_PAPER, BL_TEAL, BL_INK)
