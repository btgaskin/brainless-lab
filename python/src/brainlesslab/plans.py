"""One plan representation and small operation constructors."""

from __future__ import annotations

import hashlib
import importlib
import itertools
import json
import tomllib
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Mapping

import tomli_w

from .specs import (
    BENCHMARK_TASKS, CompositionSpec, EvaluationSpec, EvaluationTarget, Intervention,
    NodeSpec, NumericalPolicy, Plan, TaskSpec, Value, plain,
)


def digest(value: object) -> str:
    return hashlib.sha256(json.dumps(plain(value), sort_keys=True, separators=(",", ":"),
                                    allow_nan=False).encode()).hexdigest()


def model_module(kind: str):
    # Resolve once per cohort. Configuration cannot select an arbitrary import.
    if kind not in ("falandays", "sorn"):
        raise ValueError("unsupported node")
    return importlib.import_module(f"brainlesslab.models.{kind}")


@dataclass(frozen=True)
class ResolvedTarget:
    target: EvaluationTarget
    horizon: int
    model_config: object
    n_inputs: int
    n_effectors: int
    neural_frames: int
    outcome_key: str
    upper_bound: float
    task_options: Mapping[str, object]


@dataclass(frozen=True)
class ResolvedPlan:
    request: Plan
    targets: tuple[ResolvedTarget, ...]
    contract_hash: str


def resolve(plan: Plan) -> ResolvedPlan:
    from .tasks import definition, resolve as resolve_task, validate_controller

    targets = []
    for target in plan.targets:
        comp = target.composition
        module = model_module(comp.node.kind)
        config_type = module.FalandaysConfig if comp.node.kind == "falandays" else module.SORNConfig
        config = config_type(**comp.node.parameters)
        info = definition(comp.task)
        horizon = plan.evaluation.horizon or info.default_horizon
        scored = horizon - plan.evaluation.warmup
        if scored <= 0:
            raise ValueError("horizon must exceed warm-up")
        if not plan.diagnostic and scored < info.minimum_scored_ticks:
            raise ValueError(f"{comp.task.kind} requires {info.minimum_scored_ticks} scored ticks")
        # Task option validation is allocation-free. World tapes are prepared
        # only after execution's memory admission.
        if comp.task.kind not in ("tracking", "pong") and plan.evaluation.warmup:
            raise ValueError("episode tasks require warmup=0")
        if info.is_probe and horizon < info.default_horizon:
            raise ValueError("probe horizon must contain the entire episode or session")
        validate_controller(comp.task, target.controller)
        frozen_weights = frozen_plasticity = blind = shuffled = False
        for intervention in sorted(target.interventions, key=lambda i: (i.tick, i.verb)):
            verb = intervention.verb
            if verb.startswith("freeze_") and not config.learn_on:
                raise ValueError("cannot freeze learning which is already disabled")
            if verb == "freeze_weights":
                if frozen_weights or frozen_plasticity or (comp.node.kind == "falandays" and config.lrate_wmat == 0):
                    raise ValueError("freeze_weights would not change the declared mechanism")
                frozen_weights = True
            elif verb == "freeze_plasticity":
                if frozen_plasticity or (comp.node.kind == "falandays" and config.lrate_wmat == 0 and config.lrate_targ == 0):
                    raise ValueError("freeze_plasticity would not change the declared mechanism")
                if any(i.tick == intervention.tick and i.verb == "freeze_weights" for i in target.interventions):
                    raise ValueError("same-tick freeze_weights and freeze_plasticity are redundant")
                frozen_plasticity = True
            elif verb == "blind_input":
                if blind or comp.input_gain == 0:
                    raise ValueError("blind_input would not change the declared interface")
                blind = True
            elif verb == "shuffle_input":
                if shuffled or blind or comp.input_gain == 0 or info.n_inputs < 2:
                    raise ValueError("shuffle_input would not change the declared interface")
                shuffled = True
        for intervention in target.interventions:
            if intervention.tick > horizon:
                raise ValueError("intervention is beyond the trial horizon")
            if target.controller != "reservoir":
                raise ValueError("reservoir interventions require a reservoir controller")
        if plan.operation == "calibrate":
            if target.controller != "reference_null" or plan.evaluation.seed_partition != "calibration":
                raise ValueError("calibration requires the reference null and calibration seed bank")
            if plan.diagnostic or plan.evaluation.blocks * plan.evaluation.trials_per_block != 1024:
                raise ValueError("empirical calibration requires 1024 full independent trajectories")
        targets.append(ResolvedTarget(target, horizon, config, info.n_inputs, info.n_effectors,
                                      info.neural_frames, info.outcome_key, info.upper_bound,
                                      resolve_task(comp.task)))
    return ResolvedPlan(plan, tuple(targets), digest({"request": plan, "targets": targets}))


def _checked(cls, data: Mapping[str, object]):
    try:
        return cls(**data)
    except TypeError as exc:
        raise ValueError(f"invalid {cls.__name__} fields: {exc}") from exc


def read_plan(path: str | Path) -> Plan:
    with Path(path).open("rb") as stream:
        data = tomllib.load(stream)
    if data.pop("format", None) != "brainlesslab-plan" or data.pop("format_version", None) != 4:
        raise ValueError("requires fresh Python plan v4; historical plans require archived Julia")
    targets = []
    for item in data.pop("targets", []):
        item = dict(item)
        composition = dict(item.pop("composition", {}))
        node = _checked(NodeSpec, composition.pop("node", {}))
        task = _checked(TaskSpec, composition.pop("task", {}))
        comp = _checked(CompositionSpec, {**composition, "node": node, "task": task})
        interventions = tuple(_checked(Intervention, v) for v in item.pop("interventions", []))
        targets.append(_checked(EvaluationTarget, {**item, "composition": comp, "interventions": interventions}))
    evaluation = _checked(EvaluationSpec, data.pop("evaluation", {}))
    numerics = _checked(NumericalPolicy, data.pop("numerics", {}))
    return _checked(Plan, {**data, "targets": tuple(targets), "evaluation": evaluation, "numerics": numerics})


def without_none(value: object) -> object:
    if isinstance(value, dict):
        return {k: without_none(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [without_none(v) for v in value]
    return value


def write_plan(plan: Plan, path: str | Path) -> Path:
    payload = {"format": "brainlesslab-plan", "format_version": 4, **plain(plan)}
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(tomli_w.dumps(without_none(payload)), encoding="utf-8")
    return destination


def profile(composition: CompositionSpec, *, evaluation: EvaluationSpec | None = None,
            numerics: NumericalPolicy | None = None, id="profile", diagnostic=False) -> Plan:
    return Plan(id, (EvaluationTarget("baseline", composition),), evaluation or EvaluationSpec(),
                numerics or NumericalPolicy(), "profile", diagnostic=diagnostic)


def sweep(composition: CompositionSpec, axes: Mapping[str, tuple[Value, ...]], *,
          evaluation: EvaluationSpec | None = None, numerics: NumericalPolicy | None = None,
          id="sweep", diagnostic=False) -> Plan:
    if not axes or any(not values for values in axes.values()):
        raise ValueError("sweep needs non-empty explicit parameter axes")
    names = tuple(axes)
    targets = []
    for values in itertools.product(*(axes[name] for name in names)):
        parameters = {**composition.node.parameters, **dict(zip(names, values, strict=True))}
        comp = replace(composition, node=replace(composition.node, parameters=parameters))
        targets.append(EvaluationTarget(digest(parameters)[:16], comp, label=str(dict(zip(names, values, strict=True)))))
    return Plan(id, tuple(targets), evaluation or EvaluationSpec(), numerics or NumericalPolicy(),
                "sweep", diagnostic=diagnostic)


def ablate(composition: CompositionSpec, verbs=("freeze_weights", "freeze_plasticity"), *,
           tick=1, evaluation=None, numerics=None, id="ablation", diagnostic=False) -> Plan:
    targets = [EvaluationTarget("baseline", composition)]
    targets.extend(EvaluationTarget(verb, composition, interventions=(Intervention(tick, verb),)) for verb in verbs)
    return Plan(id, tuple(targets), evaluation or EvaluationSpec(), numerics or NumericalPolicy(),
                "ablate", diagnostic=diagnostic)


def benchmark(node: NodeSpec | None = None, *, count=200, evaluation=None,
              numerics=None, id="benchmark") -> Plan:
    targets = tuple(target for task in BENCHMARK_TASKS for target in (
        EvaluationTarget(task, CompositionSpec(node or NodeSpec(), TaskSpec(task), count),
                         pairing_key=f"benchmark/{task}"),
        EvaluationTarget(f"{task}_null", CompositionSpec(node or NodeSpec(), TaskSpec(task), count),
                         pairing_key=f"benchmark/{task}", controller="reference_null")))
    return Plan(id, targets, evaluation or EvaluationSpec(), numerics or NumericalPolicy(), "benchmark")
