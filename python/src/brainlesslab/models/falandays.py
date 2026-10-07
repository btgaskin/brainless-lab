"""Homeostatic Falandays reservoir, with ordered destination-owned updates.

Runtime weights use ``[batch, destination, source]``. Archival fixtures use
source-by-destination matrices; :meth:`InitialState.from_source_target` is the
explicit adapter. The fixture gates establish implementation conformance only.
"""

from collections.abc import Sequence
from dataclasses import dataclass, fields

import numpy as np
import quadrants as qd

from ._validation import validate_cast


@dataclass(frozen=True)
class FalandaysConfig:
    leak: float = 0.25
    lrate_wmat: float = 1.0
    lrate_targ: float = 0.01
    threshold_mult: float = 2.0
    targ_min: float = 1.0
    input_weight: float = 1.875
    weight_init_std: float = 1.0
    learn_on: bool = True
    link_p: float = 0.1
    input_link_p: tuple[float, ...] | None = None
    weight_init_mode: str = "excitatory"
    recurrent_init_scale: float = 1.0
    rectify: bool = False
    repair_masks: bool = False
    axis: str = "unsigned"
    inhibitory_frac: float = 0.25
    drive: str = "none"
    membrane_noise: float = 0.0
    noise_gain: float = 0.0

    def __post_init__(self):
        for item in fields(self):
            value = getattr(self, item.name)
            if isinstance(value, (int, float)) and not np.isfinite(value):
                raise ValueError(f"{item.name} must be finite")
        for name in ("link_p", "inhibitory_frac", "leak"):
            if not 0 <= getattr(self, name) <= 1:
                raise ValueError(f"{name} must lie in [0, 1]")
        for name in (
            "lrate_wmat",
            "lrate_targ",
            "input_weight",
            "weight_init_std",
            "recurrent_init_scale",
            "membrane_noise",
            "noise_gain",
        ):
            if getattr(self, name) < 0:
                raise ValueError(f"{name} must be nonnegative")
        if self.threshold_mult <= 0 or self.targ_min <= 0:
            raise ValueError("threshold_mult and targ_min must be positive")
        if self.weight_init_mode not in ("excitatory", "pong_mixed", "legacy_normal"):
            raise ValueError("unknown weight_init_mode")
        if self.axis not in ("unsigned", "dale") or self.drive not in ("none", "oosawa"):
            raise ValueError("unknown axis or drive")
        if self.input_link_p is not None:
            probabilities = tuple(float(p) for p in self.input_link_p)
            if any(not np.isfinite(p) or not 0 <= p <= 1 for p in probabilities):
                raise ValueError("input_link_p must contain probabilities")
            object.__setattr__(self, "input_link_p", probabilities)


@dataclass(frozen=True)
class InitialState:
    config: FalandaysConfig
    weights: np.ndarray
    recurrent_mask: np.ndarray
    input_weights: np.ndarray
    output_mask: np.ndarray
    signs: np.ndarray
    acts: np.ndarray
    targets: np.ndarray
    spikes: np.ndarray

    def __post_init__(self):
        # Frozen metadata alone does not confer ownership of mutable arrays.
        if not np.all(np.isin(self.recurrent_mask, (0, 1))):
            raise ValueError("recurrent_mask must be binary before integer conversion")
        if not np.all(np.isin(self.signs, (-1, 1))):
            raise ValueError("signs must be exactly +1 or -1")
        if not np.all(np.isin(np.asarray(self.signs), (-1, 1))):
            raise ValueError("signs must be +1 or -1")
        for name in (
            "weights",
            "recurrent_mask",
            "input_weights",
            "output_mask",
            "signs",
            "acts",
            "targets",
            "spikes",
        ):
            kind = np.int32 if name in ("recurrent_mask", "signs") else np.float64
            value = np.array(getattr(self, name), dtype=kind, order="C", copy=True)
            if not np.all(np.isfinite(value)):
                raise ValueError(f"{name} must be finite")
            value.flags.writeable = False
            object.__setattr__(self, name, value)
        n = self.acts.size
        if self.acts.shape != (n,) or n < 1:
            raise ValueError("acts must be a nonempty vector")
        if self.weights.shape != (n, n) or self.recurrent_mask.shape != (n, n):
            raise ValueError("recurrent arrays must be destination-by-source square matrices")
        if (
            self.input_weights.ndim != 2
            or self.input_weights.shape[0] != n
            or self.input_weights.shape[1] < 1
        ):
            raise ValueError("input_weights must be node-by-receptor")
        if (
            self.output_mask.ndim != 2
            or self.output_mask.shape[0] != n
            or self.output_mask.shape[1] < 1
        ):
            raise ValueError("output_mask must be node-by-effector")
        if any(getattr(self, name).shape != (n,) for name in ("signs", "targets", "spikes")):
            raise ValueError("node vectors must have equal widths")
        if not np.all(np.isin(self.signs, (-1, 1))):
            raise ValueError("signs must be +1 or -1")
        if np.any(self.output_mask < 0):
            raise ValueError("output_mask must be nonnegative")
        if self.config.axis == "unsigned" and np.any(self.signs != 1):
            raise ValueError("unsigned axis requires positive signs")

    @classmethod
    def from_source_target(
        cls, config, *, wmat0, recurrent_mask, input_wmat, output_mask, sign=None
    ):
        """Own and transpose the declared archival source-by-target arrays."""
        n = np.asarray(wmat0).shape[0]
        return cls(
            config,
            np.asarray(wmat0).T,
            np.asarray(recurrent_mask).T,
            np.asarray(input_wmat).T,
            output_mask,
            np.ones(n, dtype=np.int32) if sign is None else sign,
            np.zeros(n),
            np.full(n, config.targ_min),
            np.zeros(n),
        )


def construct(
    config: FalandaysConfig, count: int, n_inputs: int, n_effectors: int, rng: np.random.Generator
) -> InitialState:
    """Construct seeded wiring; RNG equality with Julia is not a contract."""
    if any(
        isinstance(v, bool) or not isinstance(v, (int, np.integer)) or v < 1
        for v in (count, n_inputs, n_effectors)
    ):
        raise ValueError("node and port counts must be positive integers")
    if not isinstance(rng, np.random.Generator):
        raise TypeError("rng must be an owned numpy Generator")
    probabilities = config.input_link_p
    if probabilities is not None and len(probabilities) != n_inputs:
        raise ValueError("input_link_p needs one probability per receptor")
    signs = np.ones(count, dtype=np.int32)
    if config.axis == "dale":
        signs[rng.random(count) < config.inhibitory_frac] = -1
    mask = rng.random((count, count)) < config.link_p
    np.fill_diagonal(mask, False)
    input_p = config.link_p if probabilities is None else np.array(probabilities)[None, :]
    input_mask = rng.random((count, n_inputs)) < input_p
    output_mask = rng.random((count, n_effectors)) < config.link_p
    if config.repair_masks:
        eligible = np.flatnonzero(
            np.full(n_inputs, config.link_p) if probabilities is None else probabilities
        )
        if config.axis == "unsigned" and eligible.size:
            for i in range(count):
                if not mask[i].any() and not input_mask[i].any():
                    input_mask[i, rng.choice(eligible)] = True
        for e in range(n_effectors):
            if not output_mask[:, e].any():
                output_mask[rng.integers(count), e] = True
    if config.axis == "dale":
        weights = np.maximum(0.0, 1.0 + 0.2 * rng.standard_normal((count, count)))
    elif config.weight_init_mode == "excitatory":
        weights = config.input_weight + 0.1 * rng.standard_normal((count, count))
    elif config.weight_init_mode == "pong_mixed":
        inhibitory = rng.random((count, count)) < 0.25
        negative = -1.0 + 0.1 * rng.standard_normal((count, count))
        neutral = 0.2 * rng.standard_normal((count, count))
        weights = np.where(inhibitory, negative, neutral)
    else:
        weights = config.weight_init_std * rng.standard_normal((count, count))
    weights *= mask
    weights *= config.recurrent_init_scale
    return InitialState(
        config,
        weights,
        mask,
        input_mask * config.input_weight,
        output_mask,
        signs,
        np.zeros(count),
        np.full(count, config.targ_min),
        np.zeros(count),
    )


# Live annotations are intentional: Quadrants expands these frozen bundles.
@dataclass(frozen=True)
class _State:
    acts: qd.types.NDArray[None, 2]
    targets: qd.types.NDArray[None, 2]
    spikes: qd.types.NDArray[None, 2]
    previous: qd.types.NDArray[None, 2]
    errors: qd.types.NDArray[None, 2]
    counts: qd.types.NDArray[None, 2]
    weights: qd.types.NDArray[None, 3]
    effectors: qd.types.NDArray[None, 2]
    finite: qd.types.NDArray[qd.i32, 1]
    learning: qd.types.NDArray[qd.i32, 1]
    weight_learning: qd.types.NDArray[qd.i32, 1]
    raw_finite: qd.types.NDArray[qd.i32, 2]


@dataclass(frozen=True)
class _Fixed:
    mask: qd.types.NDArray[qd.i32, 3]
    inputs: qd.types.NDArray[None, 3]
    outputs: qd.types.NDArray[None, 3]
    signs: qd.types.NDArray[qd.i32, 2]
    params: qd.types.NDArray[None, 2]
    flags: qd.types.NDArray[qd.i32, 2]
    weights0: qd.types.NDArray[None, 3]
    acts0: qd.types.NDArray[None, 2]
    targets0: qd.types.NDArray[None, 2]
    spikes0: qd.types.NDArray[None, 2]


@qd.kernel(fastcache=True)
def _save_previous(s: _State, active: qd.types.NDArray[qd.i32, 1]):
    for b, i in qd.ndrange(s.spikes.shape[0], s.spikes.shape[1]):
        if active[b] != 0:
            s.previous[b, i] = s.spikes[b, i]


@qd.func
def _real_zero(precision: qd.template()):  # pyright: ignore[reportInvalidTypeForm]
    if qd.static(precision == 64):
        return qd.cast(0, qd.f64)
    else:
        return qd.cast(0, qd.f32)


@qd.kernel(fastcache=True)
def _integrate(
    s: _State,
    f: _Fixed,
    inputs: qd.types.NDArray[None, 2],
    noise: qd.types.NDArray[None, 2],
    active: qd.types.NDArray[qd.i32, 1],
    real: qd.template(),  # pyright: ignore[reportInvalidTypeForm]
):
    for b, i in qd.ndrange(s.acts.shape[0], s.acts.shape[1]):
        if active[b] != 0:
            sensory = _real_zero(real)
            recurrent = _real_zero(real)
            count = _real_zero(real)
            for r in range(inputs.shape[1]):
                sensory += inputs[b, r] * f.inputs[b, i, r]
            for j in range(s.acts.shape[1]):
                recurrent += s.weights[b, i, j] * (s.previous[b, j] * f.signs[b, j])
                if f.mask[b, i, j] != 0 and s.previous[b, j] != 0:
                    count += 1
            a = s.acts[b, i] * (1 - f.params[b, 0]) + sensory + recurrent
            threshold = s.targets[b, i] * f.params[b, 3]
            if f.flags[b, 2] != 0:
                sigma = f.params[b, 5] + f.params[b, 6] * qd.max(0, threshold - a)
                a += noise[b, i] * sigma
            s.raw_finite[b, i] = qd.cast(_is_finite(a) and _is_finite(threshold), qd.i32)
            if f.flags[b, 0] != 0 and a < 0:
                a = _real_zero(real)
            spike = _real_zero(real)
            if a >= threshold:
                spike = _real_zero(real) + 1
                a -= threshold
            s.acts[b, i] = a
            s.spikes[b, i] = spike
            s.errors[b, i] = a - s.targets[b, i]
            s.counts[b, i] = count


@qd.kernel(fastcache=True)
def _learn(s: _State, f: _Fixed, active: qd.types.NDArray[qd.i32, 1]):
    for b, i in qd.ndrange(s.acts.shape[0], s.acts.shape[1]):
        if active[b] != 0 and s.learning[b] != 0:
            if s.weight_learning[b] != 0 and s.counts[b, i] > 0:
                delta = s.errors[b, i] / s.counts[b, i] * f.params[b, 1]
                for j in range(s.acts.shape[1]):
                    if f.mask[b, i, j] != 0 and s.previous[b, j] != 0:
                        change = delta
                        if f.flags[b, 1] != 0 and f.signs[b, j] == -1:
                            change = -delta
                        weight = s.weights[b, i, j] - change
                        if not _is_finite(weight):
                            s.raw_finite[b, i] = 0
                        if f.flags[b, 1] != 0 and weight < 0:
                            weight = 0
                        s.weights[b, i, j] = weight
            if s.weight_learning[b] != 0 and f.flags[b, 1] != 0:
                any_active = 0
                for k in range(s.counts.shape[1]):
                    if s.counts[b, k] > 0:
                        any_active = 1
                if any_active != 0:
                    for j in range(s.acts.shape[1]):
                        if f.mask[b, i, j] == 0:
                            s.weights[b, i, j] = 0
            target = s.targets[b, i] + s.errors[b, i] * f.params[b, 2]
            if not _is_finite(target):
                s.raw_finite[b, i] = 0
            s.targets[b, i] = qd.max(f.params[b, 4], target)


@qd.kernel(fastcache=True)
def _readout(s: _State, f: _Fixed, active: qd.types.NDArray[qd.i32, 1], real: qd.template()):  # pyright: ignore[reportInvalidTypeForm]
    for b, e in qd.ndrange(s.effectors.shape[0], s.effectors.shape[1]):
        if active[b] != 0:
            total = _real_zero(real)
            count = _real_zero(real)
            for i in range(s.spikes.shape[1]):
                total += s.spikes[b, i] * f.outputs[b, i, e]
                count += f.outputs[b, i, e]
            value = _real_zero(real)
            if count > 0:
                value = total / count
            s.effectors[b, e] = value


@qd.func
def _is_finite(value):
    return not qd.math.isnan(value) and not qd.math.isinf(value)


@qd.kernel(fastcache=True)
def _finite(s: _State, active: qd.types.NDArray[qd.i32, 1]):
    for b in range(s.acts.shape[0]):
        if active[b] != 0:
            valid = 1
            for i in range(s.acts.shape[1]):
                if s.raw_finite[b, i] == 0:
                    valid = 0
                if (
                    not _is_finite(s.acts[b, i])
                    or not _is_finite(s.targets[b, i])
                    or not _is_finite(s.errors[b, i])
                ):
                    valid = 0
            for e in range(s.effectors.shape[1]):
                if not _is_finite(s.effectors[b, e]):
                    valid = 0
            s.finite[b] = valid


@qd.kernel(fastcache=True)
def _reset(s: _State, f: _Fixed, active: qd.types.NDArray[qd.i32, 1]):
    for b, i in qd.ndrange(s.acts.shape[0], s.acts.shape[1]):
        if active[b] != 0:
            s.acts[b, i] = f.acts0[b, i]
            s.targets[b, i] = f.targets0[b, i]
            s.spikes[b, i] = f.spikes0[b, i]
            s.previous[b, i] = 0
            s.errors[b, i] = 0
            s.counts[b, i] = 0
            s.raw_finite[b, i] = 1
            for j in range(s.acts.shape[1]):
                s.weights[b, i, j] = f.weights0[b, i, j]
    for b in range(s.acts.shape[0]):
        if active[b] != 0:
            s.learning[b] = f.flags[b, 3]
            s.weight_learning[b] = f.flags[b, 3]
            s.finite[b] = 1
            for e in range(s.effectors.shape[1]):
                s.effectors[b, e] = 0


@qd.kernel(fastcache=True)
def _freeze(s: _State, active: qd.types.NDArray[qd.i32, 1], all_plasticity: qd.i32):
    for b in range(s.learning.shape[0]):
        if active[b] != 0:
            s.weight_learning[b] = 0
            if all_plasticity != 0:
                s.learning[b] = 0


class ModelBatch:
    """Persistent device state; initialise the Quadrants runtime before construction."""

    def __init__(self, initials: Sequence[InitialState], dtype="float64"):
        initials = tuple(initials)
        if not initials:
            raise ValueError("a model batch needs at least one initial state")
        dtype = np.dtype(dtype)
        if dtype not in (np.dtype("float64"), np.dtype("float32")):
            raise ValueError("dtype must be float64 or float32")
        validate_cast(initials, dtype)
        shape = (
            initials[0].acts.size,
            initials[0].input_weights.shape[1],
            initials[0].output_mask.shape[1],
        )
        if any(
            (v.acts.size, v.input_weights.shape[1], v.output_mask.shape[1]) != shape
            for v in initials
        ):
            raise ValueError("batch slots must have equal node and port widths")
        self.batch_size = len(initials)
        self.count, self.n_inputs, self.n_effectors = shape
        self.dtype = dtype
        self._real = qd.f64 if dtype == np.dtype("float64") else qd.f32
        self._precision = 64 if dtype == np.dtype("float64") else 32

        def upload(values, integer=False):
            host = np.array(values, dtype=np.int32 if integer else dtype, order="C", copy=True)
            array = qd.ndarray(qd.i32 if integer else self._real, host.shape)
            array.from_numpy(host)
            return array

        def stack(name, integer=False):
            return upload(np.stack([getattr(v, name) for v in initials]), integer)

        acts, targets, spikes, weights = (
            stack(name) for name in ("acts", "targets", "spikes", "weights")
        )

        def zeros():
            return upload(np.zeros((self.batch_size, self.count)))

        learning = upload([v.config.learn_on for v in initials], True)
        self._state = _State(
            acts,
            targets,
            spikes,
            zeros(),
            zeros(),
            zeros(),
            weights,
            upload(np.zeros((self.batch_size, self.n_effectors))),
            upload(np.ones(self.batch_size), True),
            learning,
            upload([v.config.learn_on for v in initials], True),
            upload(np.ones((self.batch_size, self.count)), True),
        )
        self._fixed = _Fixed(
            stack("recurrent_mask", True),
            stack("input_weights"),
            stack("output_mask"),
            stack("signs", True),
            upload(
                [
                    [
                        v.config.leak,
                        v.config.lrate_wmat,
                        v.config.lrate_targ,
                        v.config.threshold_mult,
                        v.config.targ_min,
                        v.config.membrane_noise,
                        v.config.noise_gain,
                    ]
                    for v in initials
                ]
            ),
            upload(
                [
                    [
                        v.config.rectify,
                        v.config.axis == "dale",
                        v.config.drive == "oosawa",
                        v.config.learn_on,
                    ]
                    for v in initials
                ],
                True,
            ),
            stack("weights"),
            stack("acts"),
            stack("targets"),
            stack("spikes"),
        )
        _readout(self._state, self._fixed, upload(np.ones(self.batch_size), True), self._precision)

    @property
    def activity(self):
        return self._state.spikes

    @property
    def effectors(self):
        return self._state.effectors

    @property
    def finite(self):
        return self._state.finite

    def _check_active(self, active):
        if active.shape != (self.batch_size,) or active.dtype != qd.i32:
            raise ValueError("active must be a rank-one int32 Quadrants array matching batch width")

    def step(self, inputs, noise, active):
        self._check_active(active)
        if inputs.shape != (self.batch_size, self.n_inputs) or noise.shape != (
            self.batch_size,
            self.count,
        ):
            raise ValueError("input or noise shape does not match model batch")
        if inputs.dtype != self._real or noise.dtype != self._real:
            raise ValueError("inputs and noise must match the model dtype")
        _save_previous(self._state, active)
        _integrate(self._state, self._fixed, inputs, noise, active, self._precision)
        _learn(self._state, self._fixed, active)
        _readout(self._state, self._fixed, active, self._precision)
        _finite(self._state, active)

    def reset(self, active):
        self._check_active(active)
        _reset(self._state, self._fixed, active)
        _readout(self._state, self._fixed, active, self._precision)

    def freeze_weights(self, active):
        self._check_active(active)
        _freeze(self._state, active, 0)

    def freeze_plasticity(self, active):
        self._check_active(active)
        _freeze(self._state, active, 1)

    def snapshot(self):
        """Return independent host arrays for diagnostics, outside the hot path."""
        return {
            item.name: np.array(getattr(self._state, item.name).to_numpy(), copy=True)
            for item in fields(_State)
        }
