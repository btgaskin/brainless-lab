"""Compact results retain scientific identity without retaining device state."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field

from .analysis import ProbeEvent, ProbeTrial
from .calibration import AdjustedInterval, CalibrationRecord
from .plans import ResolvedPlan
from .specs import TaskOutcome


@dataclass(frozen=True)
class TrialResult:
    target_id: str
    task: str
    block_id: int
    trial_id: int
    outcome: TaskOutcome
    status: str
    completed_ticks: int
    neural_frames: int
    world_seed: str
    wiring_id: str
    seeds: Mapping[str, str]
    error: str | None = None


@dataclass(frozen=True)
class TargetSummary:
    target_id: str
    task: str
    outcome: TaskOutcome
    completed_trials: int
    failed_trials: int
    independent_blocks: int
    independent_unit: str
    raw_interval: tuple[float, float] | None
    adjusted: AdjustedInterval | None = None


@dataclass(frozen=True)
class EvaluationResult:
    resolved: ResolvedPlan
    trials: tuple[TrialResult, ...]
    summaries: tuple[TargetSummary, ...]
    contrasts: tuple[Mapping[str, object], ...] = ()
    events: tuple[ProbeEvent, ...] = ()
    probe_trials: tuple[ProbeTrial, ...] = ()
    calibrations: tuple[CalibrationRecord, ...] = ()
    replays: Mapping[str, tuple[Mapping[str, object], ...]] = field(default_factory=dict)
    metadata: Mapping[str, object] = field(default_factory=dict)
    timings: Mapping[str, float] = field(default_factory=dict)


def task_outcome(result: EvaluationResult) -> TaskOutcome | dict[str, TaskOutcome]:
    outcomes = {summary.target_id: summary.outcome for summary in result.summaries}
    return next(iter(outcomes.values())) if len(outcomes) == 1 else outcomes
