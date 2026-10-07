"""Scientific specifications are independent of device buffers and placement."""

from __future__ import annotations

import math
from dataclasses import dataclass, field, fields, is_dataclass
from types import MappingProxyType
from typing import Literal, Mapping

type Value = str | int | float | bool | tuple[Value, ...]
type Options = Mapping[str, Value]

TASKS = (
    "tracking", "pong", "cartpole_plank_easy", "delayed_cue", "recall_interference",
    "delayed_xor", "evidence_accumulation", "context_integration", "temporal_order",
    "reversal_adaptation",
)
BENCHMARK_TASKS = TASKS[:4]


def _positive(value: int, name: str, minimum: int = 1) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{name} must be an integer >= {minimum}")


def _options(values: Options) -> Options:
    def freeze(value: object) -> Value:
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("configuration numbers must be finite")
        if isinstance(value, (str, int, float, bool)):
            return value
        if isinstance(value, (tuple, list)):
            return tuple(freeze(v) for v in value)
        raise TypeError(f"unsupported configuration value: {type(value).__name__}")

    if any(not isinstance(key, str) for key in values):
        raise TypeError("configuration keys must be strings")
    return MappingProxyType({key: freeze(value) for key, value in values.items()})


@dataclass(frozen=True)
class NodeSpec:
    kind: Literal["falandays", "sorn"] = "falandays"
    parameters: Options = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.kind not in ("falandays", "sorn"):
            raise ValueError(f"unsupported node {self.kind!r}; archived nodes require Julia")
        object.__setattr__(self, "parameters", _options(self.parameters))


@dataclass(frozen=True)
class TaskSpec:
    kind: str = "delayed_cue"
    options: Options = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.kind not in TASKS:
            raise ValueError(f"unsupported task {self.kind!r}; historical tasks require Julia")
        object.__setattr__(self, "options", _options(self.options))


@dataclass(frozen=True)
class CompositionSpec:
    node: NodeSpec = field(default_factory=NodeSpec)
    task: TaskSpec = field(default_factory=TaskSpec)
    count: int = 200
    input_gain: float = 1.0

    def __post_init__(self) -> None:
        _positive(self.count, "count")
        if not math.isfinite(self.input_gain) or self.input_gain < 0:
            raise ValueError("input_gain must be finite and non-negative")


@dataclass(frozen=True)
class EvaluationSpec:
    blocks: int = 1
    trials_per_block: int = 1
    horizon: int | None = None
    warmup: int = 0
    construction_scope: Literal["evaluation", "block", "trial"] = "block"
    root_seed: int = 0
    seed_partition: str = "development"

    def __post_init__(self) -> None:
        _positive(self.blocks, "blocks")
        _positive(self.trials_per_block, "trials_per_block")
        _positive(self.warmup, "warmup", 0)
        _positive(self.root_seed, "root_seed", 0)
        if self.horizon is not None:
            _positive(self.horizon, "horizon")
            if self.horizon <= self.warmup:
                raise ValueError("horizon must exceed warmup")
        if self.construction_scope not in ("evaluation", "block", "trial"):
            raise ValueError("invalid construction_scope")
        if not self.seed_partition:
            raise ValueError("seed_partition must name a disjoint scientific seed bank")


@dataclass(frozen=True)
class Intervention:
    tick: int
    verb: Literal["freeze_weights", "freeze_plasticity", "blind_input", "shuffle_input"]

    def __post_init__(self) -> None:
        _positive(self.tick, "intervention tick")
        if self.verb not in ("freeze_weights", "freeze_plasticity", "blind_input", "shuffle_input"):
            raise ValueError(f"unsupported intervention {self.verb!r}")


@dataclass(frozen=True)
class EvaluationTarget:
    id: str
    composition: CompositionSpec = field(default_factory=CompositionSpec)
    label: str = ""
    pairing_key: str = "paired-worlds"
    construction_key: str = "paired-construction"
    mechanism_key: str = "paired-mechanism"
    controller: str = "reservoir"
    interventions: tuple[Intervention, ...] = ()

    def __post_init__(self) -> None:
        for name in ("id", "pairing_key", "construction_key", "mechanism_key"):
            if not getattr(self, name):
                raise ValueError(f"{name} must be a non-empty stable identity")
        object.__setattr__(self, "interventions", tuple(self.interventions))
        if len({(i.tick, i.verb) for i in self.interventions}) != len(self.interventions):
            raise ValueError("duplicate intervention")


@dataclass(frozen=True)
class NumericalPolicy:
    dtype: Literal["float64", "float32"] = "float64"
    fast_math: bool = False
    reduction: Literal["ordered"] = "ordered"
    rng: Literal["philox-host-v1"] = "philox-host-v1"

    def __post_init__(self) -> None:
        if self.dtype not in ("float64", "float32"):
            raise ValueError("dtype must be float64 or float32")
        if self.fast_math or self.reduction != "ordered" or self.rng != "philox-host-v1":
            raise ValueError("this release supports strict ordered arithmetic and philox-host-v1")


@dataclass(frozen=True)
class ExecutionSpec:
    backend: Literal["cpu", "metal"] = "cpu"
    batch_size: int = 32
    memory_budget_bytes: int = 256 * 1024 * 1024
    reserve_fraction: float = 0.25
    noise_tile_frames: int = 64
    recording: Literal["summary", "probe_events", "replay"] = "summary"
    recording_budget_bytes: int = 32 * 1024 * 1024
    cpu_threads: int = 1
    cache: bool = True

    def __post_init__(self) -> None:
        if self.backend not in ("cpu", "metal"):
            raise ValueError("only CPU and Metal are implemented; other backends are unqualified")
        for name in ("batch_size", "memory_budget_bytes", "noise_tile_frames", "cpu_threads"):
            _positive(getattr(self, name), name)
        _positive(self.recording_budget_bytes, "recording_budget_bytes", 0)
        if not 0 <= self.reserve_fraction < 1:
            raise ValueError("reserve_fraction must be within [0, 1)")
        if self.recording not in ("summary", "probe_events", "replay"):
            raise ValueError("unknown recording channel")

    @property
    def allocation_budget(self) -> int:
        return int(self.memory_budget_bytes * (1 - self.reserve_fraction))


@dataclass(frozen=True)
class Plan:
    id: str
    targets: tuple[EvaluationTarget, ...]
    evaluation: EvaluationSpec = field(default_factory=EvaluationSpec)
    numerics: NumericalPolicy = field(default_factory=NumericalPolicy)
    operation: str = "profile"
    question: str = ""
    version: str = "1"
    evidence: str = "exploratory"
    diagnostic: bool = False

    def __post_init__(self) -> None:
        object.__setattr__(self, "targets", tuple(self.targets))
        if not self.id or not self.targets:
            raise ValueError("a plan needs an id and at least one target")
        if len({t.id for t in self.targets}) != len(self.targets):
            raise ValueError("condition IDs must be unique")
        if self.operation not in ("profile", "sweep", "ablate", "benchmark", "calibrate"):
            raise ValueError("unsupported operation")
        if self.evidence not in ("planned", "exploratory", "tuned", "frozen", "confirmed", "promoted", "retired"):
            raise ValueError("unknown evidence state")
        if self.evidence in ("confirmed", "promoted"):
            raise ValueError("the development runner cannot confer confirmed or promoted evidence")


@dataclass(frozen=True)
class TaskOutcome:
    key: str
    raw: float | None
    normalised: float | None = None
    normalisation_status: str = "calibration_unavailable"
    calibration_id: str | None = None
    scoring_window: int = 0


def plain(value: object) -> object:
    """Produce portable data without deepcopying immutable mapping proxies."""
    if is_dataclass(value) and not isinstance(value, type):
        return {f.name: plain(getattr(value, f.name)) for f in fields(value)}
    if isinstance(value, Mapping):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)):
        return [plain(v) for v in value]
    return value
