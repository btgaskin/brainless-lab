"""Task-bound null calibration and independent uncertainty propagation.

Upper bounds describe declared task opportunity. They are not claims that an
oracle controller has been implemented or achieved that bound.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, fields
from types import MappingProxyType
import hashlib
import json
import math

import numpy as np

from .analysis import DECODABLE_TASKS
from .random import generator
from .specs import NumericalPolicy, TaskOutcome, plain

NULL_TRAJECTORIES = 1024
UPPER_BOUNDS = {"tracking": 1., "pong": 1., "cartpole_plank_easy": 15000.,
                **{task: 1. for task in (*DECODABLE_TASKS, "reversal_adaptation")}}


def _freeze_mapping(value):
    # Serialise once to detach all caller-owned nested values, then freeze them.
    copied = json.loads(json.dumps(plain(value), allow_nan=False))

    def freeze(item):
        if isinstance(item, dict):
            return MappingProxyType({key: freeze(v) for key, v in sorted(item.items())})
        if isinstance(item, list):
            return tuple(freeze(v) for v in item)
        return item

    return freeze(copied)


def _digest(value):
    encoded = json.dumps(plain(value), sort_keys=True, separators=(",", ":"),
                         allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


@dataclass(frozen=True)
class CalibrationSignature:
    task: str
    task_options: Mapping[str, object]
    initialisation_policy: str
    scoring_horizon: int
    warmup: int
    action_cadence: int
    numerics: NumericalPolicy
    world_source_hashes: Mapping[str, str]
    null_policy: str = "iid-uniform-random-action-v1"
    rng_scheme: str = "philox-host-v1"

    def __post_init__(self):
        if self.task not in UPPER_BOUNDS:
            raise ValueError("unsupported calibration task")
        if self.scoring_horizon < 1 or self.warmup < 0 or self.action_cadence < 1:
            raise ValueError("invalid scoring horizon, warm-up or action cadence")
        if not self.initialisation_policy or not self.null_policy:
            raise ValueError("calibration requires explicit initialisation and null policies")
        if self.rng_scheme != self.numerics.rng:
            raise ValueError("calibration RNG scheme must match the numerical policy")
        if not self.world_source_hashes or any(not key or not value
                                             for key, value in self.world_source_hashes.items()):
            raise ValueError("calibration requires world-source hashes")
        forbidden = {"node", "node_kind", "node_count", "count", "n_nodes", "input_gain", "topology"}
        if forbidden.intersection(self.task_options):
            raise ValueError("reservoir design and input gain do not belong to task calibration")
        object.__setattr__(self, "task_options", _freeze_mapping(self.task_options))
        object.__setattr__(self, "world_source_hashes", _freeze_mapping(self.world_source_hashes))

    @property
    def id(self):
        return _digest(self)


@dataclass(frozen=True)
class CalibrationRecord:
    id: str
    signature: CalibrationSignature
    method: str
    upper_bound: float
    null_mean: float
    trial_scores: tuple[float, ...]
    trajectory_ids: tuple[str | int, ...]
    null_standard_error: float
    null_interval: tuple[float, float]
    root_seed: int
    bootstrap_repetitions: int
    frozen: bool = True

    def __post_init__(self):
        object.__setattr__(self, "trial_scores", tuple(map(float, self.trial_scores)))
        object.__setattr__(self, "trajectory_ids", tuple(self.trajectory_ids))
        object.__setattr__(self, "null_interval", tuple(map(float, self.null_interval)))
        if not self.frozen or self.method not in ("analytic", "empirical"):
            raise ValueError("calibration records must use a declared frozen method")
        if self.method == "empirical" and (len(self.trial_scores) != NULL_TRAJECTORIES or
                                            len(set(self.trajectory_ids)) != NULL_TRAJECTORIES):
            raise ValueError("empirical calibration records require 1024 independent trajectory identities")
        if self.method == "analytic" and (self.trial_scores or self.trajectory_ids):
            raise ValueError("analytic calibration records do not contain empirical trajectories")
        payload = {field.name: getattr(self, field.name) for field in fields(self) if field.name != "id"}
        if self.id != _digest(payload):
            raise ValueError("calibration content hash does not match the record")


def _record(signature, method, upper_bound, mean, scores, ids, se, interval,
            root_seed, repetitions):
    payload = dict(signature=signature, method=method, upper_bound=float(upper_bound),
                   null_mean=float(mean), trial_scores=tuple(map(float, scores)),
                   trajectory_ids=tuple(ids), null_standard_error=float(se),
                   null_interval=tuple(map(float, interval)), root_seed=root_seed,
                   bootstrap_repetitions=repetitions, frozen=True)
    return CalibrationRecord(_digest(payload), **payload)


def create_empirical_calibration(signature: CalibrationSignature,
                                 trial_scores: Sequence[float], *, upper_bound=None,
                                 trajectory_ids=None, root_seed=0,
                                 repetitions=2000) -> CalibrationRecord:
    """Freeze exactly 1,024 independently generated null trajectory scores.

    Callers establish independence through their seed ledger and generation
    protocol. This function validates unique IDs and computes uncertainty; it
    never executes trajectories or accepts evidence on a maintainer's behalf.
    """
    scores = np.asarray(trial_scores, dtype=np.float64)
    if scores.shape != (NULL_TRAJECTORIES,) or not np.isfinite(scores).all():
        raise ValueError("empirical calibration requires 1024 finite independent trajectory scores")
    upper = UPPER_BOUNDS[signature.task] if upper_bound is None else float(upper_bound)
    if not math.isfinite(upper) or upper <= 0 or np.any(scores < 0) or np.any(scores > upper):
        raise ValueError("null scores must lie within the declared task bounds")
    ids = tuple(range(NULL_TRAJECTORIES)) if trajectory_ids is None else tuple(trajectory_ids)
    if len(ids) != NULL_TRAJECTORIES or len(set(ids)) != NULL_TRAJECTORIES:
        raise ValueError("null trajectories require 1024 unique stable identities")
    if any(not isinstance(i, (str, int)) or isinstance(i, bool) for i in ids):
        raise TypeError("trajectory identities must be portable strings or integers")
    if repetitions < 2:
        raise ValueError("at least two bootstrap repetitions are required")
    rng = generator(root_seed, "calibration", "null-mean-bootstrap", signature.id)
    means = np.empty(repetitions)
    for index in range(repetitions):
        means[index] = np.mean(scores[rng.integers(0, len(scores), size=len(scores))])
    interval = np.quantile(means, [0.025, 0.975], method="linear")
    return _record(signature, "empirical", upper, np.mean(scores), scores, ids,
                   np.std(scores, ddof=1) / math.sqrt(len(scores)), interval,
                   root_seed, repetitions)


def analytic_calibration(signature: CalibrationSignature, *, upper_bound=1.,
                         null_mean=0.5) -> CalibrationRecord:
    if signature.task not in (*DECODABLE_TASKS, "reversal_adaptation"):
        raise ValueError("analytic chance calibration is declared only for binary probe tasks")
    if upper_bound != 1. or null_mean != 0.5:
        raise ValueError("binary analytic calibration has chance 0.5 and upper bound 1")
    return _record(signature, "analytic", upper_bound, null_mean, (), (), 0.,
                   (null_mean, null_mean), 0, 0)


def null_adjusted(raw: float | None, calibration: CalibrationRecord | None, *,
                  key="task_score", scoring_window=0) -> TaskOutcome:
    if raw is None:
        return TaskOutcome(key, None, normalisation_status="no_scalar_outcome",
                           scoring_window=scoring_window)
    if not math.isfinite(raw):
        raise ValueError("raw task outcome must be finite")
    if calibration is None:
        return TaskOutcome(key, float(raw), scoring_window=scoring_window)
    denominator = calibration.upper_bound - calibration.null_mean
    if denominator <= 0 or not math.isfinite(denominator):
        return TaskOutcome(key, float(raw), normalisation_status="invalid_calibration_denominator",
                           calibration_id=calibration.id, scoring_window=scoring_window)
    return TaskOutcome(key, float(raw), (raw - calibration.null_mean) / denominator,
                       f"null_adjusted_{calibration.method}", calibration.id, scoring_window)


@dataclass(frozen=True)
class AdjustedInterval:
    estimate: float | None
    interval: tuple[float, float] | None
    raw_mean: float
    raw_interval: tuple[float, float] | None
    null_mean: float
    null_interval: tuple[float, float] | None
    status: str
    invalid_denominator_draws: int
    repetitions: int
    calibration_id: str


def adjusted_interval(model_block_means: Sequence[float], calibration: CalibrationRecord, *,
                      seed=0, repetitions=2000) -> AdjustedInterval:
    """Independently resample model blocks and calibration trajectories.

    A non-positive denominator makes the adjusted interval unavailable. No
    bootstrap draws are removed. Raw and null intervals remain separate.
    """
    model = np.asarray(model_block_means, dtype=np.float64)
    if model.ndim != 1 or not len(model) or not np.isfinite(model).all():
        raise ValueError("model block means must be a finite non-empty vector")
    if repetitions < 2:
        raise ValueError("at least two bootstrap repetitions are required")
    raw = float(np.mean(model))
    outcome = null_adjusted(raw, calibration)
    if len(model) < 2:
        return AdjustedInterval(outcome.normalised, None, raw, None, calibration.null_mean,
                                calibration.null_interval, "insufficient_independent_blocks",
                                0, 0, calibration.id)
    model_rng = generator(seed, "uncertainty", "model-block-bootstrap", calibration.id)
    null_rng = generator(seed, "uncertainty", "calibration-trajectory-bootstrap", calibration.id)
    null_scores = np.asarray(calibration.trial_scores)
    raw_draws, null_draws = np.empty(repetitions), np.empty(repetitions)
    for index in range(repetitions):
        raw_draws[index] = np.mean(model[model_rng.integers(0, len(model), size=len(model))])
        null_draws[index] = (np.mean(null_scores[null_rng.integers(0, len(null_scores), size=len(null_scores))])
                             if len(null_scores) else calibration.null_mean)
    denominators = calibration.upper_bound - null_draws
    invalid = int(np.count_nonzero(~np.isfinite(denominators) | (denominators <= 0)))
    raw_interval = tuple(map(float, np.quantile(raw_draws, [0.025, 0.975], method="linear")))
    null_interval = tuple(map(float, np.quantile(null_draws, [0.025, 0.975], method="linear")))
    if invalid or outcome.normalised is None:
        return AdjustedInterval(outcome.normalised, None, raw, raw_interval, calibration.null_mean,
                                null_interval, "invalid_calibration_denominator", invalid,
                                repetitions, calibration.id)
    ratios = (raw_draws - null_draws) / denominators
    interval = tuple(map(float, np.quantile(ratios, [0.025, 0.975], method="linear")))
    return AdjustedInterval(outcome.normalised, interval, raw, raw_interval, calibration.null_mean,
                            null_interval, "available", 0, repetitions, calibration.id)
