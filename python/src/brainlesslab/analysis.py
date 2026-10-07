"""Offline whole-trial diagnostics over sparse emitted-activity observations.

Labels are analysis metadata. The fitted decoder never controls a task, and an
accuracy here is not a measure of cognition or a native task outcome.
"""

from __future__ import annotations

import math
from collections import defaultdict
from collections.abc import Sequence
from dataclasses import dataclass

import numpy as np

from .random import generator

DECODABLE_TASKS = (
    "delayed_cue",
    "recall_interference",
    "delayed_xor",
    "evidence_accumulation",
    "context_integration",
    "temporal_order",
)
POINTS = ("cue_end", "delay_end", "response")


@dataclass(frozen=True)
class ProbeEvent:
    target_id: str
    task: str
    block_id: int
    trial_id: int
    entity_id: str
    feature_ids: tuple[str, ...]
    point: str
    tick: int
    round: int
    label: int
    features: np.ndarray
    channel: str = "emitted_activity"

    def __post_init__(self):
        features = np.array(self.features, dtype=np.float64, copy=True)
        ids = tuple(self.feature_ids)
        if features.ndim != 1 or not len(features) or not np.isfinite(features).all():
            raise ValueError("probe features must be a finite non-empty vector")
        if len(ids) != len(features) or len(set(ids)) != len(ids) or any(not i for i in ids):
            raise ValueError("stable feature IDs must uniquely identify each feature")
        if not self.target_id or not self.entity_id:
            raise ValueError("probe events require stable target and entity IDs")
        if self.label not in (1, 2) or self.tick < 0 or self.round != 1:
            raise ValueError("binary probe diagnostics require labels 1/2 and round 1")
        features.setflags(write=False)
        object.__setattr__(self, "features", features)
        object.__setattr__(self, "feature_ids", ids)


@dataclass(frozen=True)
class ProbeTrial:
    target_id: str
    task: str
    block_id: int
    trial_id: int
    native_score: float
    wiring_id: str
    world_seed: str | int
    node_signature: str
    interface_signature: str
    construction_scope: str = "block"
    reset: str = "full"


@dataclass(frozen=True)
class DecoderFit:
    regularisation: float
    weights: tuple[float, ...]
    intercept: float
    centre: tuple[float, ...]
    scale: tuple[float, ...]
    predictions: tuple[int, ...]
    validation_accuracy: float


@dataclass(frozen=True)
class DecoderResult:
    target_id: str
    task: str
    block_id: int
    point: str
    entity_id: str
    feature_ids: tuple[str, ...]
    trial_ids: tuple[int, ...]
    fit_trial_ids: tuple[int, ...]
    validation_trial_ids: tuple[int, ...]
    evaluation_trial_ids: tuple[int, ...]
    labels: tuple[int, ...]
    permutation_labels: tuple[int, ...]
    native_scores: tuple[float, ...]
    fitted: DecoderFit
    permutation: DecoderFit
    accuracy: float
    native_accuracy: float
    permutation_accuracy: float
    constant_accuracy: float
    constant_prediction: int
    chance_accuracy: float = 0.5
    independent_blocks: int = 1
    channel: str = "emitted_activity"


def _ridge(features, labels, fit, validation, grid) -> DecoderFit:
    centre = np.mean(features[fit], axis=0)
    scale = np.std(features[fit], axis=0, ddof=0)
    scale[scale == 0] = 1
    standard = (features - centre) / scale
    targets = np.where(labels[fit] == 1, 1.0, -1.0)
    intercept = float(np.mean(targets))
    gram = standard[fit].T @ standard[fit]
    rhs = standard[fit].T @ (targets - intercept)
    best = None
    for regularisation in grid:
        weights = np.linalg.solve(gram + regularisation * np.eye(features.shape[1]), rhs)
        predictions = np.where(standard @ weights + intercept >= 0, 1, 2)
        accuracy = float(np.mean(predictions[validation] == labels[validation]))
        if best is None or accuracy > best.validation_accuracy:
            best = DecoderFit(
                float(regularisation),
                tuple(map(float, weights)),
                intercept,
                tuple(map(float, centre)),
                tuple(map(float, scale)),
                tuple(map(int, predictions)),
                accuracy,
            )
    if best is None:
        raise ValueError("ridge requires at least one regularisation value")
    return best


def decode(
    events: Sequence[ProbeEvent],
    trials: Sequence[ProbeTrial],
    *,
    points=POINTS,
    fit_trials=256,
    validation_trials=128,
    evaluation_trials=256,
    lambdas=(1e-4, 1e-2, 1.0, 100.0),
    split_seed=701,
    permutation_seed=702,
    memory_budget_bytes=32 * 1024 * 1024,
) -> tuple[DecoderResult, ...]:
    """Fit independent ridge diagnostics at each point with one shared trial split.

    Exactly the declared number of whole trials is required per wiring block.
    Scaling uses fit trials only; tuning uses validation labels only. The null
    separately permutes fit and validation labels, retaining evaluation truth.
    A conservative dense-solver storage check bounds the offline allocation.
    """
    points = tuple(points)
    if not points or len(set(points)) != len(points) or any(p not in POINTS for p in points):
        raise ValueError("points must be distinct cue_end, delay_end or response")
    counts = (fit_trials, validation_trials, evaluation_trials)
    if any(isinstance(n, bool) or not isinstance(n, int) or n < 2 for n in counts):
        raise ValueError("each split requires at least two whole trials")
    grid = tuple(sorted(set(lambdas)))
    if not grid or any(not math.isfinite(v) or v <= 0 for v in grid):
        raise ValueError("ridge lambdas must be finite and positive")
    groups: defaultdict[tuple[str, str, int], list[ProbeTrial]] = defaultdict(list)
    trial_keys = set()
    for trial in trials:
        key = (trial.target_id, trial.task, trial.block_id, trial.trial_id)
        if key in trial_keys:
            raise ValueError("duplicate decoder trial IDs")
        trial_keys.add(key)
        if trial.task not in DECODABLE_TASKS:
            raise ValueError("decoder supports only the six stimulus-driven binary probe tasks")
        if trial.construction_scope != "block" or trial.reset != "full":
            raise ValueError("decoder requires block construction and full reset")
        if not math.isfinite(trial.native_score) or not 0 <= trial.native_score <= 1:
            raise ValueError("every trial needs a completed native score in [0, 1]")
        groups[key[:3]].append(trial)
    if not groups:
        raise ValueError("decoder requires trials")
    event_map = {}
    for event in events:
        key = (event.target_id, event.task, event.block_id, event.trial_id)
        if key not in trial_keys:
            raise ValueError("probe event has no corresponding trial")
        if event.point not in points:
            continue
        point_key = (*key, event.point)
        if point_key in event_map:
            raise ValueError("exactly one observation per trial and point is required")
        if event.channel != "emitted_activity" or event.round != 1:
            raise ValueError("decoder requires emitted activity from round 1")
        event_map[point_key] = event
    results = []
    for identity, members in sorted(groups.items()):
        members.sort(key=lambda trial: trial.trial_id)
        if len(members) != sum(counts):
            raise ValueError(f"decoder requires exactly {sum(counts)} whole trials per block")
        provenance = {(t.wiring_id, t.node_signature, t.interface_signature) for t in members}
        if len(provenance) != 1 or any(not v for v in next(iter(provenance))):
            raise ValueError("trials must share fixed wiring, node parameters and interface")
        if len({t.world_seed for t in members}) != len(members):
            raise ValueError("trial worlds must have distinct seeds")
        order = generator(split_seed, "analysis", "probe-split").permutation(len(members))
        a, b, _ = counts
        fit, validation, evaluation = order[:a], order[a : a + b], order[a + b :]
        trial_ids = tuple(t.trial_id for t in members)
        native = np.array([t.native_score for t in members])
        reference_labels = None
        reference_features = None
        for point in points:
            observations = []
            for trial in members:
                key = (*identity, trial.trial_id, point)
                if key not in event_map:
                    raise ValueError(
                        "missing observation: exactly one event per trial and point is required"
                    )
                observations.append(event_map[key])
            reference = observations[0]
            feature_identity = (reference.entity_id, reference.feature_ids)
            if any((e.entity_id, e.feature_ids) != feature_identity for e in observations):
                raise ValueError("incompatible entity or feature IDs across trials")
            if reference_features is not None and feature_identity != reference_features:
                raise ValueError("feature identities must be stable across observation points")
            reference_features = feature_identity
            feature_count = len(reference.feature_ids)
            # X, standardised X, fit copies and solver matrices/workspace.
            required = 8 * (6 * len(members) * feature_count + 4 * feature_count**2)
            if required > memory_budget_bytes:
                raise MemoryError("decoder exceeds the declared offline memory budget")
            features = np.stack([e.features for e in observations])
            labels = np.array([e.label for e in observations])
            if reference_labels is not None and not np.array_equal(labels, reference_labels):
                raise ValueError("labels must agree across observation points within each trial")
            reference_labels = labels.copy()
            for subset in (fit, validation, evaluation):
                if len(np.unique(labels[subset])) != 2:
                    raise ValueError(
                        "every split needs both classes; revise the declared split seed"
                    )
            fitted = _ridge(features, labels, fit, validation, grid)
            permuted = labels.copy()
            rng = generator(permutation_seed, "analysis", "probe-label-permutation")
            permuted[fit] = rng.permutation(labels[fit])
            permuted[validation] = rng.permutation(labels[validation])
            null = _ridge(features, permuted, fit, validation, grid)
            constant = 1 if np.count_nonzero(labels[fit] == 1) >= len(fit) / 2 else 2
            results.append(
                DecoderResult(
                    *identity,
                    point,
                    reference.entity_id,
                    reference.feature_ids,
                    trial_ids,
                    tuple(trial_ids[i] for i in fit),
                    tuple(trial_ids[i] for i in validation),
                    tuple(trial_ids[i] for i in evaluation),
                    tuple(map(int, labels)),
                    tuple(map(int, permuted)),
                    tuple(map(float, native)),
                    fitted,
                    null,
                    float(np.mean(np.array(fitted.predictions)[evaluation] == labels[evaluation])),
                    float(np.mean(native[evaluation])),
                    float(np.mean(np.array(null.predictions)[evaluation] == labels[evaluation])),
                    float(np.mean(labels[evaluation] == constant)),
                    constant,
                )
            )
    return tuple(results)
