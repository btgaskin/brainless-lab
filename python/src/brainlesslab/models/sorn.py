"""Dense SORN equation implementation; conformance is not author-trajectory parity.

All matrices use [destination, source]. ``inhibitory_fraction`` retains the
historical name but denotes the I/E ratio, rather than the fraction of all units.
Construction is host-side; neural dynamics and adaptation run in Quadrants.
"""

import math
from collections.abc import Sequence
from dataclasses import dataclass, fields

import numpy as np
import quadrants as qd

from ._validation import validate_cast


@dataclass(frozen=True)
class SORNConfig:
    inhibitory_fraction: float = 0.2
    p_ee: float = 10.0 / 166.0
    p_ei: float = 1.0
    p_ie: float = 1.0
    p_input: float = 0.05
    p_output: float = 0.05
    ee_row_sum: float = 1.0
    ei_row_sum: float = 1.0
    ie_row_sum: float = 1.0
    input_row_sum: float = 1.0
    T_E_max: float = 0.5
    T_I_max: float = 1.0
    eta_stdp: float = 0.001
    eta_ip: float = 0.001
    H_ip: float = 0.1
    learn_on: bool = True

    def __post_init__(self):
        probabilities = {
            "inhibitory_fraction",
            "p_ee",
            "p_ei",
            "p_ie",
            "p_input",
            "p_output",
            "H_ip",
        }
        for field in fields(self):
            if field.name == "learn_on":
                if not isinstance(self.learn_on, bool):
                    raise TypeError("learn_on must be a bool")
                continue
            value = getattr(self, field.name)
            if not math.isfinite(value) or value < 0:
                raise ValueError(f"{field.name} must be finite and non-negative")
            if field.name in probabilities and value > 1:
                raise ValueError(f"{field.name} must be in [0, 1]")


@dataclass(frozen=True)
class InitialState:
    config: SORNConfig
    count: int
    n_inputs: int
    n_effectors: int
    n_e: int
    w_ee: np.ndarray
    ee_mask: np.ndarray
    c_e: np.ndarray
    w_ei: np.ndarray
    w_ie: np.ndarray
    w_eu: np.ndarray
    output_mask: np.ndarray
    t_e: np.ndarray
    t_i: np.ndarray
    x: np.ndarray
    y: np.ndarray

    def __post_init__(self):
        for name in ("count", "n_inputs", "n_effectors", "n_e"):
            value = getattr(self, name)
            if isinstance(value, bool) or not isinstance(value, (int, np.integer)) or value < 1:
                raise ValueError(f"{name} must be a positive integer")
        if self.n_e > self.count:
            raise ValueError("n_e cannot exceed count")
        n_i = self.count - self.n_e
        shapes = {
            "w_ee": (self.n_e, self.n_e),
            "ee_mask": (self.n_e, self.n_e),
            "c_e": (self.n_e,),
            "w_ei": (self.n_e, n_i),
            "w_ie": (n_i, self.n_e),
            "w_eu": (self.n_e, self.n_inputs),
            "output_mask": (self.n_effectors, self.n_e),
            "t_e": (self.n_e,),
            "t_i": (n_i,),
            "x": (self.n_e,),
            "y": (n_i,),
        }
        for name, shape in shapes.items():
            raw = np.asarray(getattr(self, name))
            if raw.shape != shape or not np.all(np.isfinite(raw)):
                raise ValueError(f"{name} must be finite and have shape {shape}")
            if name in ("ee_mask", "output_mask", "x", "y") and not np.all(np.isin(raw, (0, 1))):
                raise ValueError(f"{name} must be binary before conversion")
            owned = np.array(
                raw, dtype=bool if name in ("ee_mask", "output_mask") else np.float64, copy=True
            )
            object.__setattr__(self, name, owned)


def _mask(rows, columns, probability, rng, no_self=False):
    mask = rng.random((rows, columns)) < probability
    if no_self:
        np.fill_diagonal(mask, False)
    if columns:
        for row in range(rows):
            if not mask[row].any():
                candidates = np.arange(columns)
                if no_self:
                    candidates = candidates[candidates != row]
                if len(candidates):
                    mask[row, rng.choice(candidates)] = True
    return mask


def _fanout(rows, columns, fraction, rng):
    mask = np.zeros((rows, columns), dtype=bool)
    fanout = min(rows, max(1, round(fraction * rows)))
    for column in range(columns):
        mask[rng.permutation(rows)[:fanout], column] = True
    return mask


def _weights(mask, target, rng):
    weights: np.ndarray = np.zeros(mask.shape, dtype=np.float64)
    if target:
        weights[mask] = rng.random(np.count_nonzero(mask))
        for row in weights:
            total = sum(row)
            if total > 0:
                row *= target / total
    return weights


def construct(
    config: SORNConfig, count: int, n_inputs: int, n_effectors: int, rng: np.random.Generator
) -> InitialState:
    for name, value in (("count", count), ("n_inputs", n_inputs), ("n_effectors", n_effectors)):
        if isinstance(value, bool) or not isinstance(value, (int, np.integer)) or value < 1:
            raise ValueError(f"{name} must be a positive integer")
    if not isinstance(rng, np.random.Generator):
        raise TypeError("rng must be a numpy.random.Generator")
    n_e = min(count, max(1, round(count / (1 + config.inhibitory_fraction))))
    n_i = count - n_e
    ee = _mask(n_e, n_e, config.p_ee, rng, no_self=True)
    ei = _mask(n_e, n_i, config.p_ei, rng)
    ie = _mask(n_i, n_e, config.p_ie, rng)
    inputs = _fanout(n_e, n_inputs, config.p_input, rng)
    outputs = _fanout(n_e, n_effectors, config.p_output, rng).T.copy()
    w_ee = _weights(ee, config.ee_row_sum, rng)
    return InitialState(
        config,
        count,
        n_inputs,
        n_effectors,
        n_e,
        w_ee,
        ee.copy(),
        np.sum(w_ee, axis=1),
        _weights(ei, config.ei_row_sum, rng),
        _weights(ie, config.ie_row_sum, rng),
        _weights(inputs, config.input_row_sum, rng),
        outputs,
        config.T_E_max * rng.random(n_e),
        config.T_I_max * rng.random(n_i),
        np.zeros(n_e),
        np.zeros(n_i),
    )


# Ranks are part of the kernel contract; batch and node counts are runtime values.
# Do not postpone these annotations: Quadrants inspects their concrete types.
@dataclass(frozen=True)
class Arrays:
    w_ee: qd.types.NDArray[None, 3]
    ee_mask: qd.types.NDArray[qd.i32, 3]
    c_e: qd.types.NDArray[None, 2]
    w_ei: qd.types.NDArray[None, 3]
    w_ie: qd.types.NDArray[None, 3]
    w_eu: qd.types.NDArray[None, 3]
    output_mask: qd.types.NDArray[qd.i32, 3]
    t_e: qd.types.NDArray[None, 2]
    t_i: qd.types.NDArray[None, 2]
    x: qd.types.NDArray[None, 2]
    y: qd.types.NDArray[None, 2]
    prev_x: qd.types.NDArray[None, 2]
    prev_y: qd.types.NDArray[None, 2]
    parameters: qd.types.NDArray[None, 2]
    plasticity: qd.types.NDArray[qd.i32, 2]
    activity: qd.types.NDArray[None, 2]
    drive: qd.types.NDArray[None, 2]
    effectors: qd.types.NDArray[None, 2]
    finite: qd.types.NDArray[qd.i32, 1]
    adaptation_finite: qd.types.NDArray[qd.i32, 2]


@qd.kernel(fastcache=True)
def _remember(s: Arrays, active: qd.types.NDArray[qd.i32, 1], n_i: qd.i32):
    for b, i in qd.ndrange(s.x.shape[0], s.x.shape[1]):
        if active[b] != 0:
            s.prev_x[b, i] = s.x[b, i]
    for b, i in qd.ndrange(s.y.shape[0], n_i):
        if active[b] != 0:
            s.prev_y[b, i] = s.y[b, i]


@qd.kernel(fastcache=True)
def _advance(
    s: Arrays, inputs: qd.types.NDArray[None, 2], active: qd.types.NDArray[qd.i32, 1], n_i: qd.i32
):
    for b, i in qd.ndrange(s.x.shape[0], s.x.shape[1]):
        if active[b] != 0:
            # Each destination owns its ordered sums. There are no float atomics.
            exc = s.x[b, i] * 0
            inh = exc
            drive = exc
            for j in range(s.x.shape[1]):
                exc = exc + s.w_ee[b, i, j] * s.prev_x[b, j]
            for k in range(n_i):
                inh = inh + s.w_ei[b, i, k] * s.prev_y[b, k]
            for q in range(inputs.shape[1]):
                drive = drive + s.w_eu[b, i, q] * inputs[b, q]
            s.drive[b, i] = exc - inh + drive - s.t_e[b, i]
            s.x[b, i] = s.drive[b, i] >= 0
    for b, k in qd.ndrange(s.y.shape[0], n_i):
        if active[b] != 0:
            exc = s.y[b, k] * 0
            for j in range(s.x.shape[1]):
                exc = exc + s.w_ie[b, k, j] * s.prev_x[b, j]
            s.drive[b, s.x.shape[1] + k] = exc - s.t_i[b, k]
            s.y[b, k] = s.drive[b, s.x.shape[1] + k] >= 0


@qd.kernel(fastcache=True)
def _adapt(s: Arrays, active: qd.types.NDArray[qd.i32, 1]):
    for b, i in qd.ndrange(s.x.shape[0], s.x.shape[1]):
        if active[b] != 0:
            s.adaptation_finite[b, i] = 1
            if s.plasticity[b, 0] != 0:
                total = s.x[b, i] * 0
                for j in range(s.x.shape[1]):
                    weight = s.x[b, i] * 0
                    if s.ee_mask[b, i, j] != 0:
                        weight = s.w_ee[b, i, j] + s.parameters[b, 0] * (
                            s.x[b, i] * s.prev_x[b, j] - s.prev_x[b, i] * s.x[b, j]
                        )
                        if qd.math.isnan(weight) or qd.math.isinf(weight):
                            s.adaptation_finite[b, i] = 0
                        if weight <= 0:
                            weight = s.x[b, i] * 0
                            s.ee_mask[b, i, j] = 0
                    s.w_ee[b, i, j] = weight
                    total = total + weight
                if qd.math.isnan(total) or qd.math.isinf(total):
                    s.adaptation_finite[b, i] = 0
                if total > 0 and s.c_e[b, i] > 0:
                    scale = s.c_e[b, i] / total
                    if qd.math.isnan(scale) or qd.math.isinf(scale):
                        s.adaptation_finite[b, i] = 0
                    for j in range(s.x.shape[1]):
                        if s.ee_mask[b, i, j] != 0:
                            s.w_ee[b, i, j] = s.w_ee[b, i, j] * scale
            if s.plasticity[b, 1] != 0:
                s.t_e[b, i] = s.t_e[b, i] + s.parameters[b, 1] * (s.x[b, i] - s.parameters[b, 2])


@qd.kernel(fastcache=True)
def _emit(s: Arrays, active: qd.types.NDArray[qd.i32, 1], n_i: qd.i32):
    for b in range(s.x.shape[0]):
        if active[b] != 0:
            valid = 1
            for i in range(s.activity.shape[1]):
                valid = valid & qd.cast(
                    not qd.math.isnan(s.drive[b, i]) and not qd.math.isinf(s.drive[b, i]), qd.i32
                )
            for i in range(s.x.shape[1]):
                valid = valid & s.adaptation_finite[b, i]
                s.activity[b, i] = s.x[b, i]
                valid = valid & qd.cast(
                    not qd.math.isnan(s.t_e[b, i]) and not qd.math.isinf(s.t_e[b, i]), qd.i32
                )
            for k in range(n_i):
                s.activity[b, s.x.shape[1] + k] = s.y[b, k]
            for k in range(s.effectors.shape[1]):
                total = s.x[b, 0] * 0
                count = 0
                for i in range(s.x.shape[1]):
                    if s.output_mask[b, k, i] != 0:
                        total = total + s.x[b, i]
                        count += 1
                s.effectors[b, k] = total
                if count > 0:
                    s.effectors[b, k] = total / count
            s.finite[b] = valid


@qd.kernel(fastcache=True)
def _freeze(s: Arrays, active: qd.types.NDArray[qd.i32, 1], all_plasticity: qd.i32):
    for b in range(s.x.shape[0]):
        if active[b] != 0:
            s.plasticity[b, 0] = 0
            if all_plasticity != 0:
                s.plasticity[b, 1] = 0


@qd.kernel(fastcache=True)
def _reset(s: Arrays, initial: Arrays, active: qd.types.NDArray[qd.i32, 1], n_i: qd.i32):
    for b in range(s.x.shape[0]):
        if active[b] != 0:
            for i in range(s.x.shape[1]):
                s.adaptation_finite[b, i] = initial.adaptation_finite[b, i]
                s.x[b, i] = initial.x[b, i]
                s.prev_x[b, i] = initial.prev_x[b, i]
                s.t_e[b, i] = initial.t_e[b, i]
                s.c_e[b, i] = initial.c_e[b, i]
                s.activity[b, i] = initial.activity[b, i]
                s.drive[b, i] = initial.drive[b, i]
                for j in range(s.x.shape[1]):
                    s.w_ee[b, i, j] = initial.w_ee[b, i, j]
                    s.ee_mask[b, i, j] = initial.ee_mask[b, i, j]
                for k in range(n_i):
                    s.w_ei[b, i, k] = initial.w_ei[b, i, k]
                for q in range(s.w_eu.shape[2]):
                    s.w_eu[b, i, q] = initial.w_eu[b, i, q]
            for k in range(n_i):
                s.y[b, k] = initial.y[b, k]
                s.prev_y[b, k] = initial.prev_y[b, k]
                s.t_i[b, k] = initial.t_i[b, k]
                s.activity[b, s.x.shape[1] + k] = initial.activity[b, s.x.shape[1] + k]
                s.drive[b, s.x.shape[1] + k] = initial.drive[b, s.x.shape[1] + k]
                for j in range(s.x.shape[1]):
                    s.w_ie[b, k, j] = initial.w_ie[b, k, j]
            for k in range(s.effectors.shape[1]):
                s.effectors[b, k] = initial.effectors[b, k]
                for i in range(s.x.shape[1]):
                    s.output_mask[b, k, i] = initial.output_mask[b, k, i]
            for j in range(3):
                s.parameters[b, j] = initial.parameters[b, j]
            for j in range(2):
                s.plasticity[b, j] = initial.plasticity[b, j]
            s.finite[b] = initial.finite[b]


class ModelBatch:
    def __init__(self, initials: Sequence[InitialState], dtype="float64"):
        if not initials:
            raise ValueError("initials must not be empty")
        for state in initials:
            if not isinstance(state, InitialState):
                raise TypeError("initials must contain SORN InitialState values")
            if not 1 <= state.n_e <= state.count:
                raise ValueError("invalid excitatory population size")
            n_i = state.count - state.n_e
            expected = {
                "w_ee": (state.n_e, state.n_e),
                "ee_mask": (state.n_e, state.n_e),
                "c_e": (state.n_e,),
                "w_ei": (state.n_e, n_i),
                "w_ie": (n_i, state.n_e),
                "w_eu": (state.n_e, state.n_inputs),
                "output_mask": (state.n_effectors, state.n_e),
                "t_e": (state.n_e,),
                "t_i": (n_i,),
                "x": (state.n_e,),
                "y": (n_i,),
            }
            for name, shape in expected.items():
                value = np.asarray(getattr(state, name))
                if value.shape != shape or not np.isfinite(value).all():
                    raise ValueError(
                        f"initial {name} must have dimensions {shape} and finite values"
                    )
        first = initials[0]
        dimensions = (first.count, first.n_inputs, first.n_effectors, first.n_e)
        if any((s.count, s.n_inputs, s.n_effectors, s.n_e) != dimensions for s in initials):
            raise ValueError("batch members must have identical population and port dimensions")
        self.count, self.n_inputs, self.n_effectors, self.n_e = dimensions
        self.n_i = self.count - self.n_e
        self.batch_size = len(initials)
        np_dtype = np.dtype(dtype)
        if np_dtype not in (np.dtype("float32"), np.dtype("float64")):
            raise ValueError("dtype must be float32 or float64")
        validate_cast(initials, np_dtype)
        self.dtype = np_dtype
        qd_dtype = qd.f32 if np_dtype == np.dtype("float32") else qd.f64
        self._real = qd_dtype
        arrays = {}
        for name in (
            "w_ee",
            "ee_mask",
            "c_e",
            "w_ei",
            "w_ie",
            "w_eu",
            "output_mask",
            "t_e",
            "t_i",
            "x",
            "y",
        ):
            values = np.stack([getattr(s, name) for s in initials])
            # Quadrants backends need non-empty allocations. The padded I slot is
            # never used and snapshots expose the declared zero-width population.
            if 0 in values.shape:
                values = np.zeros(tuple(max(1, dim) for dim in values.shape), dtype=values.dtype)
            arrays[name] = values
        arrays.update(
            prev_x=arrays["x"].copy(),
            prev_y=arrays["y"].copy(),
            parameters=np.array(
                [[s.config.eta_stdp, s.config.eta_ip, s.config.H_ip] for s in initials]
            ),
            plasticity=np.array(
                [[s.config.learn_on, s.config.learn_on] for s in initials], dtype=np.int32
            ),
            activity=np.stack([np.concatenate((s.x, s.y)) for s in initials]),
            drive=np.zeros((self.batch_size, self.count)),
            effectors=np.zeros((self.batch_size, self.n_effectors)),
            finite=np.ones(self.batch_size, dtype=np.int32),
            adaptation_finite=np.ones((self.batch_size, self.n_e), dtype=np.int32),
        )

        def upload():
            uploaded = {}
            for name, values in arrays.items():
                integer = name in (
                    "ee_mask",
                    "output_mask",
                    "plasticity",
                    "finite",
                    "adaptation_finite",
                )
                value = np.ascontiguousarray(values, dtype=np.int32 if integer else np_dtype)
                device = qd.ndarray(qd.i32 if integer else qd_dtype, shape=value.shape)
                device.from_numpy(value)
                uploaded[name] = device
            return Arrays(**uploaded)

        self.state = upload()
        self.initial = upload()
        self.activity = self.state.activity
        self.effectors = self.state.effectors
        self.finite = self.state.finite

    def step(self, inputs, noise, active):
        if inputs.shape != (self.batch_size, self.n_inputs):
            raise ValueError("inputs must have [batch, input] dimensions")
        if noise.shape != (self.batch_size, self.count):
            raise ValueError("noise must have [batch, node] dimensions")
        if inputs.dtype != self._real or noise.dtype != self._real:
            raise ValueError("inputs and noise must match the model dtype")
        self._validate_active(active)
        _remember(self.state, active, self.n_i)
        _advance(self.state, inputs, active, self.n_i)
        _adapt(self.state, active)
        _emit(self.state, active, self.n_i)

    def _validate_active(self, active):
        if active.shape != (self.batch_size,) or active.dtype != qd.i32:
            raise ValueError("active must have [batch] int32 dimensions")

    def reset(self, active):
        self._validate_active(active)
        _reset(self.state, self.initial, active, self.n_i)

    def freeze_weights(self, active):
        self._validate_active(active)
        _freeze(self.state, active, 0)

    def freeze_plasticity(self, active):
        self._validate_active(active)
        _freeze(self.state, active, 1)

    def snapshot(self):
        result = {
            field.name: getattr(self.state, field.name).to_numpy().copy()
            for field in fields(Arrays)
        }
        if self.n_i == 0:
            for name in ("y", "prev_y", "t_i", "w_ie"):
                result[name] = result[name][:, :0].copy()
            result["w_ei"] = result["w_ei"][:, :, :0].copy()
        return result
