"""Validated task definitions and owned construction inputs.

Schedules and labels are diagnostic metadata. Runtime controllers receive only
the declared observation vector. The host prepares random worlds, never actions.
"""

import math
from collections.abc import Mapping
from dataclasses import dataclass
from types import MappingProxyType

import numpy as np

from ..specs import TaskSpec

DEFAULTS = {
    "tracking": dict(stim_speed_rad=math.pi / 180, movement_amp=10.0,
                     eye_offset_deg=30.0, sensor_offsets_deg=tuple(range(-60, 61, 4)),
                     sensory_gain=1.0, randomize_start=True, theta0=None, phi0=None, direction0=None),
    "pong": dict(sensory_gain=1.0),
    "cartpole_plank_easy": dict(initial_ranges=((-1.2, 1.2), (-0.05, 0.05),
                               (-0.10475, 0.10475), (-0.05, 0.05))),
    "delayed_cue": dict(cue_ticks=8, delays=(8, 32, 128), response_ticks=8, cue_mode="transient"),
    "recall_interference": dict(cue_ticks=8, delay=32, response_ticks=8, distractors=1,
                                distractor_ticks=4, cue_mode="transient", distractor_mode="random"),
    "delayed_xor": dict(cue_ticks=8, gap=32, response_ticks=8, cue_mode="transient"),
    "evidence_accumulation": dict(pulse_count=32, evidence_fraction=0.25, pulse_ticks=1,
                                  response_ticks=8, input_mode="visible"),
    "context_integration": dict(cue_ticks=8, pulse_count=32, evidence_fraction=0.25,
                                pulse_ticks=1, response_ticks=8, context_mode="transient", congruency="mixed"),
    "temporal_order": dict(cue_ticks=8, gap=8, terminal_ticks=8, response_ticks=8, input_mode="visible"),
    "reversal_adaptation": dict(rounds=96, cue_ticks=8, response_ticks=8, feedback_ticks=8,
                                reversal_range=(32, 64), feedback_mode="visible"),
}
KINDS = {name: i for i, name in enumerate(DEFAULTS)}


def _integer(value, name, minimum=1):
    if isinstance(value, bool) or not isinstance(value, (int, np.integer)) or value < minimum:
        raise ValueError(f"{name} must be an integer >= {minimum}")
    return int(value)


def _mode(value, name, allowed):
    if value not in allowed:
        raise ValueError(f"{name} must be one of {allowed}")
    return value


def resolve(spec: TaskSpec) -> dict:
    unknown = set(spec.options) - DEFAULTS[spec.kind].keys()
    if unknown:
        raise ValueError(f"unknown options for {spec.kind}: {sorted(unknown)}")
    options = DEFAULTS[spec.kind] | dict(spec.options)
    for key in ("cue_ticks", "response_ticks", "distractor_ticks", "pulse_ticks", "terminal_ticks", "feedback_ticks"):
        if key in options:
            options[key] = _integer(options[key], key)
    for key in ("gap", "delay", "distractors"):
        if key in options:
            options[key] = _integer(options[key], key, 0)
    for key in ("cue_mode", "context_mode"):
        if key in options:
            _mode(options[key], key, ("transient", "persistent", "hidden"))
    for key in ("input_mode", "feedback_mode"):
        if key in options:
            _mode(options[key], key, ("visible", "hidden"))
    if "delays" in options:
        values = tuple(_integer(v, "delays", 0) for v in options["delays"])
        if not values or len(set(values)) != len(values):
            raise ValueError("delays must be nonempty and distinct")
        options["delays"] = values
    if spec.kind == "recall_interference":
        k, d, w = (options[key] for key in ("distractors", "delay", "distractor_ticks"))
        if k and (d < 32 or k * w + k + 1 > d):
            raise ValueError("distractors need delay >= 32 and blank frames between cues")
        _mode(options["distractor_mode"], "distractor_mode", ("random", "matched", "opposite", "absent"))
    if "pulse_count" in options:
        n = options["pulse_count"] = _integer(options["pulse_count"], "pulse_count", 4)
        fraction = float(options["evidence_fraction"])
        if not math.isfinite(fraction) or not 0 < fraction < 1:
            raise ValueError("evidence_fraction must lie in (0, 1)")
        left = n * (1 + fraction) / 2
        if not left.is_integer() or not 1 <= n - left <= n - 1:
            raise ValueError("evidence counts must be integral and permit either final pulse")
        options["evidence_fraction"] = fraction
    if spec.kind == "context_integration":
        _mode(options["congruency"], "congruency", ("mixed", "congruent", "conflicting"))
    if spec.kind == "reversal_adaptation":
        n = options["rounds"] = _integer(options["rounds"], "rounds", 48)
        if len(options["reversal_range"]) != 2:
            raise ValueError("reversal_range needs two endpoints")
        lo, hi = (_integer(v, "reversal_range", 2) for v in options["reversal_range"])
        if not lo <= hi <= n - 15:
            raise ValueError("reversal must leave sixteen scored rounds")
        options["reversal_range"] = (lo, hi)
    if spec.kind in ("tracking", "pong"):
        gain = options["sensory_gain"] = float(options["sensory_gain"])
        if not math.isfinite(gain) or gain < 0:
            raise ValueError("sensory_gain must be finite and nonnegative")
    if spec.kind == "tracking":
        for key in ("stim_speed_rad", "movement_amp", "eye_offset_deg", "theta0", "phi0", "direction0"):
            if options[key] is not None:
                value = options[key] = float(options[key])
                if not math.isfinite(value):
                    raise ValueError(f"{key} must be finite")
        if options["movement_amp"] <= 0:
            raise ValueError("movement_amp must be positive")
        offsets = tuple(float(v) for v in options["sensor_offsets_deg"])
        if not offsets or not all(math.isfinite(v) for v in offsets):
            raise ValueError("sensor_offsets_deg needs finite offsets")
        options["sensor_offsets_deg"] = offsets
        if not isinstance(options["randomize_start"], bool):
            raise ValueError("randomize_start must be boolean")
    if spec.kind == "cartpole_plank_easy":
        ranges = tuple(tuple(float(x) for x in r) for r in options["initial_ranges"])
        if len(ranges) != 4 or any(len(r) != 2 or not all(map(math.isfinite, r)) or r[0] > r[1] for r in ranges):
            raise ValueError("initial_ranges needs four finite ordered pairs")
        options["initial_ranges"] = ranges
    return options


@dataclass(frozen=True)
class Definition:
    n_inputs: int
    n_effectors: int
    neural_frames: int
    default_horizon: int
    minimum_scored_ticks: int
    outcome_key: str
    upper_bound: float
    is_probe: bool


def definition(spec: TaskSpec) -> Definition:
    o = resolve(spec)
    kind = spec.kind
    if kind == "tracking":
        return Definition(2 * len(o["sensor_offsets_deg"]), 2, 1, 2000, 2000, "track_score", 1.0, False)
    if kind == "pong":
        return Definition(46, 2, 1, 7200, 6000, "hit_rate", 1.0, False)
    if kind == "cartpole_plank_easy":
        return Definition(8, 2, 24, 15000, 15000, "fitness", 15000.0, False)
    c, r = o.get("cue_ticks", 0), o["response_ticks"]
    if kind == "delayed_cue":
        width, horizon = 3, c + max(o["delays"]) + r
    elif kind == "recall_interference":
        width, horizon = 3, c + o["delay"] + r
    elif kind == "delayed_xor":
        width, horizon = 5, 2 * c + o["gap"] + r
    elif kind == "evidence_accumulation":
        width, horizon = 3, o["pulse_count"] * o["pulse_ticks"] + r
    elif kind == "context_integration":
        width, horizon = 7, c + o["pulse_count"] * o["pulse_ticks"] + r
    elif kind == "temporal_order":
        width, horizon = 4, 2 * c + o["gap"] + o["terminal_ticks"] + r
    else:
        width, horizon = 8, o["rounds"] * (c + r + o["feedback_ticks"])
    key = "recall_accuracy" if kind == "delayed_cue" else "adaptation_accuracy" if kind == "reversal_adaptation" else "probe_accuracy"
    return Definition(width, 2, 1, horizon, 1, key, 1.0, True)


def validate_controller(spec: TaskSpec, policy: str) -> str:
    """Resolve the declared controls, without constructing or inspecting a world."""
    resolve(spec)
    if policy == "reference_nullblindpolicy":
        policy = "reference_null"
    allowed = {"reservoir", "oracle", "reference_null", "constant_left", "constant_right"}
    kind = spec.kind
    if kind in ("delayed_cue", "recall_interference", "delayed_xor"):
        allowed |= {"memoryless", "last"}
    elif kind == "evidence_accumulation":
        allowed |= {"first", "last"}
    elif kind == "context_integration":
        allowed |= {"context_blind", "irrelevant", "first", "last"}
    elif kind == "temporal_order":
        allowed |= {"bag", "last"}
    elif kind == "reversal_adaptation":
        allowed |= {"fixed_mapping"}
    if policy not in allowed:
        raise ValueError(f"policy {policy!r} is not defined for {kind}")
    return policy


@dataclass(frozen=True)
class InitialState:
    spec: TaskSpec
    definition: Definition
    options: Mapping
    physical: np.ndarray
    stimuli: np.ndarray
    response_start: np.ndarray
    response_end: np.ndarray
    cue_ends: np.ndarray
    labels: np.ndarray
    round_bounds: np.ndarray
    draws: np.ndarray
    metadata: Mapping

    def __post_init__(self):
        if not isinstance(self.spec, TaskSpec):
            raise TypeError("spec must be a TaskSpec")
        if not isinstance(self.definition, Definition) or self.definition != definition(self.spec):
            raise ValueError("definition must match the task specification and ports")
        if not isinstance(self.options, Mapping) or dict(self.options) != resolve(self.spec):
            raise ValueError("options must match the resolved task specification")
        if not isinstance(self.metadata, Mapping):
            raise TypeError("metadata must be a mapping")
        integer_arrays = ("response_start", "response_end", "cue_ends", "labels", "round_bounds")
        for name in ("physical", "stimuli", "draws", *integer_arrays):
            kind = np.int32 if name in integer_arrays else np.float64
            raw = np.asarray(getattr(self, name))
            if raw.dtype.kind not in "iuf" or not np.all(np.isfinite(raw)):
                raise ValueError(f"{name} must contain finite numeric values")
            if kind == np.int32:
                limits = np.iinfo(np.int32)
                if (np.any(raw != np.floor(raw)) or np.any(raw < limits.min)
                        or np.any(raw > limits.max)):
                    raise ValueError(f"{name} must contain exactly representable int32 integers")
            value = np.array(raw, dtype=kind, order="C", copy=True)
            value.flags.writeable = False
            object.__setattr__(self, name, value)
        if self.physical.shape != (8,):
            raise ValueError("physical must have shape (8,)")
        if (self.stimuli.ndim != 2 or self.stimuli.shape[0] < 1
                or self.stimuli.shape[1] != self.definition.n_inputs):
            raise ValueError("stimuli must have shape (T, n_inputs), with T >= 1")
        if self.draws.ndim != 2 or self.draws.shape[0] < 1 or self.draws.shape[1] != 2:
            raise ValueError("draws must have shape (K, 2), with K >= 1")
        schedules = (self.response_start, self.response_end, self.cue_ends, self.labels)
        if (any(value.ndim != 1 for value in schedules)
                or len({value.size for value in schedules}) != 1):
            raise ValueError("labels, response schedules and cue ends must be equal-length vectors")
        rounds = self.labels.size
        if self.round_bounds.shape != (rounds, 2):
            raise ValueError("round_bounds must have shape (number of labels, 2)")
        if self.definition.is_probe:
            if not rounds or np.any((self.labels != 1) & (self.labels != 2)):
                raise ValueError("probes require labels 1 or 2")
            start, end = self.round_bounds.T
            if (np.any(start < 0) or np.any(end > self.stimuli.shape[0]) or np.any(start >= end)
                    or np.any(start[1:] < end[:-1]) or np.any(self.cue_ends <= start)
                    or np.any(self.cue_ends > self.response_start)
                    or np.any(self.response_start >= self.response_end)
                    or np.any(self.response_end > end)):
                raise ValueError(
                    "probe schedules must be ordered within their rounds and stimulus horizon"
                )
        elif rounds:
            raise ValueError("ordinary tasks require empty probe labels and schedules")
        if self.spec.kind == "reversal_adaptation":
            reversal = _integer(self.metadata.get("reversal_round"), "reversal_round", 2)
            lo, hi = self.options["reversal_range"]
            if (rounds != self.options["rounds"] or not lo <= reversal <= hi
                    or reversal - 1 + 15 >= rounds):
                raise ValueError(
                    "reversal must leave sixteen scored rounds within the declared range"
                )
        object.__setattr__(self, "options", MappingProxyType(dict(self.options)))
        object.__setattr__(self, "metadata", MappingProxyType(dict(self.metadata)))


def validate_precision(initials, dtype):
    """Keep required positive task parameters positive at the execution precision.

    Call before device allocation, alongside the shared finite-cast check.
    Zero sensory gain and zero stimulus speed are valid task controls.
    """
    dtype = np.dtype(dtype)
    if dtype not in (np.dtype("float32"), np.dtype("float64")):
        raise ValueError("dtype must be float64 or float32")
    for initial in initials:
        if initial.spec.kind == "tracking":
            with np.errstate(over="ignore", under="ignore"):
                movement = np.asarray(initial.options["movement_amp"], dtype=dtype)
            if not np.isfinite(movement) or movement <= 0:
                raise ValueError(
                    f"movement_amp must remain finite and positive after casting to {dtype.name}"
                )


def _pulses(rng, n, fraction, label):
    left_count = int(n * (1 + (fraction if label == 1 else -fraction)) / 2)
    final = int(rng.integers(1, 3))
    left = left_count - (final == 1)
    pulses = np.concatenate((np.ones(left, dtype=np.int32), np.full(n - 1 - left, 2, dtype=np.int32)))
    rng.shuffle(pulses)
    return np.append(pulses, final)


def prepare(spec: TaskSpec, rng: np.random.Generator, *, horizon=None) -> InitialState:
    if not isinstance(rng, np.random.Generator):
        raise TypeError("rng must be a numpy Generator")
    d, o, kind = definition(spec), resolve(spec), spec.kind
    horizon = d.default_horizon if horizon is None else _integer(horizon, "horizon")
    physical = np.zeros(8)
    draws = np.zeros((1, 2))
    stimuli = np.zeros((1, d.n_inputs))
    starts, ends, cues, labels, bounds = [], [], [], [], []
    metadata = {}
    if kind == "tracking":
        random = o["randomize_start"]
        physical[:3] = [o["theta0"] if o["theta0"] is not None else 2 * math.pi * rng.random() if random else math.pi / 2,
                        o["phi0"] if o["phi0"] is not None else 2 * math.pi * rng.random() if random else 0,
                        o["direction0"] if o["direction0"] is not None else (1 if rng.integers(2) else -1) if random else 1]
    elif kind == "pong":
        draws = rng.random((horizon + 1, 2))
        physical[:5] = [995, 1 + 498 * draws[0, 0], 250, -5, 5 if draws[0, 1] >= 0.5 else -5]
    elif kind == "cartpole_plank_easy":
        physical[:4] = [lo if lo == hi else rng.uniform(lo, hi) for lo, hi in o["initial_ranges"]]
    else:
        c, r = o.get("cue_ticks", 0), o["response_ticks"]
        length = d.default_horizon
        if kind == "delayed_cue":
            cue = int(rng.integers(1, 3))
            delay = int(rng.choice(o["delays"]))
            length = c + delay + r
            stimuli = np.zeros((length, 3))
            if o["cue_mode"] != "hidden":
                stimuli[:c, cue - 1] = 1
            if o["cue_mode"] == "persistent":
                stimuli[:, cue - 1] = 1
            starts, ends, cues, labels = [c + delay], [length], [c], [cue]
            metadata = dict(cue=cue, delay=delay)
        elif kind == "recall_interference":
            cue = int(rng.integers(1, 3))
            distractor_labels = rng.integers(1, 3, o["distractors"])
            stimuli = np.zeros((length, 3))
            if o["cue_mode"] != "hidden":
                stimuli[:c, cue - 1] = 1
            if o["cue_mode"] == "persistent":
                stimuli[:, cue - 1] = 1
            w, k, delay = o["distractor_ticks"], o["distractors"], o["delay"]
            distractor_starts = [c + i * (delay - w) // (k + 1) for i in range(1, k + 1)]
            for start, random_label in zip(distractor_starts, distractor_labels, strict=True):
                mode = o["distractor_mode"]
                label = cue if mode == "matched" else 3 - cue if mode == "opposite" else random_label
                if mode != "absent":
                    stimuli[start:start + w, :2] = 0
                    stimuli[start:start + w, label - 1] = 1
            starts, ends, cues, labels = [c + delay], [length], [c], [cue]
            metadata = dict(cue=cue, distractor_labels=tuple(int(v) for v in distractor_labels), distractor_starts=tuple(distractor_starts))
        elif kind == "delayed_xor":
            a, b = (int(v) for v in rng.integers(1, 3, 2))
            stimuli = np.zeros((length, 5))
            second = c + o["gap"]
            if o["cue_mode"] != "hidden":
                stimuli[:c, a - 1] = 1
                stimuli[second:second + c, b + 1] = 1
            if o["cue_mode"] == "persistent":
                stimuli[:, a - 1] = 1
                stimuli[second:, b + 1] = 1
            starts, ends, cues, labels = [2 * c + o["gap"]], [length], [c], [1 if a == b else 2]
            metadata = dict(first_cue=a, second_cue=b)
        elif kind in ("evidence_accumulation", "context_integration"):
            n, fraction, p = (o[key] for key in ("pulse_count", "evidence_fraction", "pulse_ticks"))
            if kind == "evidence_accumulation":
                label = int(rng.integers(1, 3))
                streams = [_pulses(rng, n, fraction, label)]
                stimuli = np.zeros((length, 3))
                visible = o["input_mode"] == "visible"
                for i, pulse in enumerate(streams[0]):
                    if visible:
                        stimuli[i * p:(i + 1) * p, pulse - 1] = 1
                cues = [p]
            else:
                context, label, other_draw = (int(v) for v in rng.integers(1, 3, 3))
                congruency = o["congruency"]
                other = label if congruency == "congruent" else 3 - label if congruency == "conflicting" else other_draw
                stream_labels = (label, other) if context == 1 else (other, label)
                streams = [_pulses(rng, n, fraction, v) for v in stream_labels]
                stimuli = np.zeros((length, 7))
                if o["context_mode"] != "hidden":
                    stimuli[:c, context - 1] = 1
                if o["context_mode"] == "persistent":
                    stimuli[:, context - 1] = 1
                for stream, pulses in enumerate(streams):
                    for i, pulse in enumerate(pulses):
                        stimuli[c + i * p:c + (i + 1) * p, 2 + 2 * stream + pulse - 1] = 1
                cues = [c]
                metadata = dict(context=context, congruent=label == other)
            starts, ends, labels = [c + n * p], [length], [label]
        elif kind == "temporal_order":
            label = int(rng.integers(1, 3))
            stimuli = np.zeros((length, 4))
            if o["input_mode"] == "visible":
                stimuli[:c, label - 1] = 1
                stimuli[c + o["gap"]:2 * c + o["gap"], 2 - label] = 1
            stimuli[2 * c + o["gap"]:length - r, 2] = 1
            starts, ends, cues, labels = [length - r], [length], [c], [label]
        else:
            mapping = bool(rng.integers(2))
            lo, hi = o["reversal_range"]
            reversal = int(rng.integers(lo, hi + 1))
            n, f = o["rounds"], o["feedback_ticks"]
            trial_cues = rng.integers(1, 3, n)
            stimuli = np.zeros((length, 8))
            for round_, cue in enumerate(trial_cues):
                start = round_ * (c + r + f)
                stimuli[start:start + c + r, cue - 1] = 1
                stimuli[start + c + r:start + c + r + f, 3] = 1
                starts.append(start + c)
                ends.append(start + c + r)
                cues.append(start + c)
                labels.append(3 - int(cue) if mapping ^ (round_ + 1 >= reversal) else int(cue))
                bounds.append((start, start + c + r + f))
            metadata = dict(reversal_round=reversal, initial_mapping=mapping)
        for start, end in zip(starts, ends, strict=True):
            stimuli[start:end, 2 if kind == "reversal_adaptation" else d.n_inputs - 1] = 1
        if not bounds:
            bounds = [(0, length)]
    metadata |= dict(cue_ends=tuple(cues), response_start=tuple(starts), response_end=tuple(ends),
                     labels=tuple(labels), round_bounds=tuple(bounds))
    return InitialState(spec, d, o, physical, stimuli, starts, ends, cues, labels,
                        np.array(bounds, dtype=np.int32).reshape(-1, 2), draws, metadata)


@dataclass(frozen=True)
class Preset:
    id: str
    task: str
    task_options: Mapping
    horizon: int


def capacity_probe_presets() -> tuple[Preset, ...]:
    """The 64 declared development cells; these confer no evidence status."""
    cells = []

    def add(task, suffix, **overrides):
        options = DEFAULTS[task] | overrides
        spec = TaskSpec(task, options)
        cells.append(Preset(f"{task}__{suffix}", task, MappingProxyType(options), definition(spec).default_horizon))

    for delay in (0, 8, 32, 128, 256):
        add("delayed_cue", f"delay_{delay}", delays=(delay,))
        if delay >= 32:
            for distractors in (1, 3):
                add("recall_interference", f"delay_{delay}_distractors_{distractors}", delay=delay, distractors=distractors)
    for gap in (0, 8, 32, 128):
        add("delayed_xor", f"gap_{gap}", gap=gap)
    for n in (16, 32, 64):
        for fraction in (0.125, 0.25, 0.5):
            suffix = f"pulses_{n}_evidence_{int(1000 * fraction)}"
            add("evidence_accumulation", suffix, pulse_count=n, evidence_fraction=fraction)
            for congruency in ("congruent", "conflicting"):
                for mode in ("transient", "persistent"):
                    add("context_integration", f"{suffix}_{congruency}_{mode}", pulse_count=n,
                        evidence_fraction=fraction, congruency=congruency, context_mode=mode)
    for gap in (0, 8, 32):
        add("temporal_order", f"gap_{gap}", gap=gap)
    add("reversal_adaptation", "single_reversal")
    return tuple(cells)
