"""A bounded, homogeneous Quadrants execution path for all public operations.

Python resolves contracts and constructs random inputs. Neural and world state,
observations, actions and scores stay on the device between tile boundaries.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, fields
import hashlib
from pathlib import Path
from time import perf_counter

import numpy as np

from .analysis import DECODABLE_TASKS, POINTS, ProbeEvent, ProbeTrial
from .backend import admit_batch, initialise
from .calibration import (CalibrationRecord, CalibrationSignature, adjusted_interval,
                          analytic_calibration, create_empirical_calibration, null_adjusted)
from .plans import ResolvedPlan, ResolvedTarget, digest, model_module, profile, resolve
from .random import SCHEME, NoiseTape, generator, seed_for
from .results import EvaluationResult, TargetSummary, TrialResult
from .specs import (CompositionSpec, EvaluationSpec, EvaluationTarget, ExecutionSpec,
                    NumericalPolicy, Plan, TaskSpec, plain)


@dataclass(frozen=True)
class _Job:
    index: int
    resolved: ResolvedTarget
    block: int
    trial: int
    world_seed: int
    construction_seed: int
    mechanism_seed: int
    wiring_id: str


def _jobs(plan: ResolvedPlan) -> tuple[_Job, ...]:
    evaluation = plan.request.evaluation
    result = []
    for resolved in plan.targets:
        target, comp = resolved.target, resolved.target.composition
        for block in range(evaluation.blocks):
            for trial in range(evaluation.trials_per_block):
                scope = ((block, trial) if evaluation.construction_scope == "trial" else
                         (block,) if evaluation.construction_scope == "block" else ())
                construction = seed_for(evaluation.root_seed, evaluation.seed_partition,
                                        "construction", target.construction_key, comp.node.kind,
                                        comp.count, resolved.n_inputs, resolved.n_effectors, *scope)
                world = seed_for(evaluation.root_seed, evaluation.seed_partition, "world",
                                 target.pairing_key, comp.task.kind, block, trial)
                mechanism = seed_for(evaluation.root_seed, evaluation.seed_partition, "drive",
                                     target.mechanism_key, comp.node.kind, block, trial)
                wiring = digest({"seed": str(construction), "node": comp.node.kind,
                                 "count": comp.count, "ports": (resolved.n_inputs, resolved.n_effectors),
                                 "config": resolved.model_config})
                result.append(_Job(len(result), resolved, block, trial, world, construction,
                                   mechanism, wiring))
    return tuple(result)


def _cohort(job: _Job) -> tuple[object, ...]:
    r, comp = job.resolved, job.resolved.target.composition
    excitatory = (max(1, min(comp.count, round(comp.count / (1 + getattr(r.model_config, "inhibitory_fraction")))))
                  if comp.node.kind == "sorn" else comp.count)
    return (comp.task.kind, r.target.controller, comp.node.kind, comp.count,
            r.n_inputs, r.n_effectors, r.neural_frames, excitatory)


def _rng(seed: int) -> np.random.Generator:
    return np.random.Generator(np.random.Philox(seed))


def _source_hashes() -> dict[str, str]:
    # Runtime and task code are part of the calibration contract. Absolute
    # checkout paths and machine names are deliberately absent.
    directory = Path(__file__).parent
    return {name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
            for name in ("tasks/_prepare.py", "tasks/_runtime.py", "random.py", "_kernels.py")}


def calibration_signature(target: ResolvedTarget, plan: Plan,
                          runtime: Mapping[str, object]) -> CalibrationSignature:
    return CalibrationSignature(target.target.composition.task.kind, target.task_options,
                                "task-factory-v1", target.horizon, plan.evaluation.warmup,
                                target.neural_frames, plan.numerics, _source_hashes(),
                                backend=str(runtime["requested_backend"]),
                                architecture=str(runtime["actual_arch"]),
                                runtime_fingerprint=str(runtime["runtime_fingerprint"]))


def _recording_admission(jobs: Sequence[_Job], execution: ExecutionSpec) -> int:
    required = 0
    for job in jobs:
        r, comp = job.resolved, job.resolved.target.composition
        if execution.recording == "probe_events":
            if comp.task.kind not in DECODABLE_TASKS or r.target.controller != "reservoir":
                raise ValueError("probe_events requires a reservoir and a single binary probe episode")
            required += 3 * (comp.count * 16 + 1024)
        elif execution.recording == "replay":
            required += r.horizon * (comp.count * 32 + r.n_inputs * 32 + 4096)
    if required > execution.recording_budget_bytes:
        raise MemoryError(f"recording needs an estimated {required} bytes; recording budget is "
                          f"{execution.recording_budget_bytes}; reduce trials or recording")
    return required


def _trajectory_bytes(job: _Job, execution: ExecutionSpec, horizon: int) -> int:
    r, comp = job.resolved, job.resolved.target.composition
    # Conservative managed-buffer allowance includes host construction copies,
    # reset copies, staging, plastic masks, scheduling and one random tile.
    # Compiler memory and the backend allocator's retained pool are not capped.
    n, ports = comp.count, r.n_inputs
    model = 0 if r.target.controller != "reservoir" else 64 * (n * n + n * ports + 12 * n)
    world = (horizon + 1) * (64 if comp.task.kind == "pong" else
                            ports * 24 if comp.task.kind in (*DECODABLE_TASKS, "reversal_adaptation") else 0)
    noise = (24 * execution.noise_tile_frames * n if comp.node.kind == "falandays"
             and r.target.controller == "reservoir" else 0)
    return model + world + noise + ports * 128 + 64 * 1024


def execute(plan: Plan | ResolvedPlan, execution: ExecutionSpec | None = None, *,
            calibrations: Sequence[CalibrationRecord] = ()) -> EvaluationResult:
    """Run a fresh plan, preserving identity across physical batch partitions.

    A runtime is owned by the process. Different backends or precisions need
    separate processes. Failure results remain visible and invalidate a target
    summary rather than quietly changing its inferential sample.
    """
    started = perf_counter()
    resolved = resolve(plan) if isinstance(plan, Plan) else plan
    execution = execution or ExecutionSpec()
    jobs = _jobs(resolved)
    recording_bytes = _recording_admission(jobs, execution)
    if any(j.resolved.neural_frames > execution.noise_tile_frames for j in jobs):
        raise ValueError("noise_tile_frames must hold at least one complete neural cycle")
    groups = defaultdict(list)
    for job in jobs:
        groups[_cohort(job)].append(job)
    capacities = {}
    for key, group in groups.items():
        longest = max(j.resolved.horizon for j in group)
        capacities[key] = admit_batch(max(_trajectory_bytes(j, execution, longest) for j in group),
                                      execution, fixed_bytes=recording_bytes)
    runtime = initialise(execution, resolved.request.numerics)
    applicable = {}
    for target in resolved.targets:
        signature = calibration_signature(target, resolved.request, runtime)
        matches = [c for c in calibrations if c.signature.id == signature.id]
        if len(matches) > 1:
            raise ValueError("ambiguous calibration records for one task contract")
        # Supplying a record for this task asserts intended reuse. Fail clearly
        # on incompatible settings; never silently report it as applied.
        if not matches and any(c.signature.task == signature.task for c in calibrations):
            raise ValueError(f"calibration signature mismatch for {signature.task}")
        applicable[target.target.id] = (matches[0] if matches else
                                       analytic_calibration(signature)
                                       if signature.task in (*DECODABLE_TASKS, "reversal_adaptation")
                                       else None)
    prepared_at = perf_counter()
    trials: dict[int, TrialResult] = {}
    events, probe_trials, replays = [], [], {}
    for key, group in groups.items():
        size = capacities[key]
        for start in range(0, len(group), size):
            batch = _run_batch(group[start:start + size], resolved, execution, applicable)
            for index, trial in batch[0]:
                trials[index] = trial
            events.extend(batch[1])
            probe_trials.extend(batch[2])
            replays.update(batch[3])
    run_finished = perf_counter()
    if set(trials) != set(range(len(jobs))):
        raise RuntimeError("internal scheduler omitted a trial")
    completed = tuple(trials[index] for index in range(len(jobs)))
    produced = []
    if resolved.request.operation == "calibrate":
        for target in resolved.targets:
            rows = [t for t in completed if t.target_id == target.target.id]
            if any(t.status != "completed" for t in rows):
                raise RuntimeError("cannot freeze a calibration containing failed trajectories")
            scores = [t.outcome.raw for t in rows if t.outcome.raw is not None]
            if len(scores) != len(rows):
                raise RuntimeError("cannot freeze a calibration containing missing outcomes")
            signature = calibration_signature(target, resolved.request, runtime)
            produced.append(analytic_calibration(signature) if signature.task in
                            (*DECODABLE_TASKS, "reversal_adaptation") else
                            create_empirical_calibration(signature, scores,
                                                         trajectory_ids=[t.world_seed for t in rows],
                                                         root_seed=resolved.request.evaluation.root_seed))
    summaries = _summarise(resolved, completed, applicable)
    used = {c.id: c for c in (*produced, *applicable.values()) if c is not None}
    return EvaluationResult(resolved, completed, summaries, _contrasts(resolved, completed),
                            tuple(events), tuple(probe_trials), tuple(used.values()), replays,
                            {**runtime, "rng_scheme": SCHEME, "source_hashes": _source_hashes(),
                             "execution": plain(execution), "batch_capacities": list(capacities.values()),
                             "reset": "full", "evidence": resolved.request.evidence,
                             "diagnostic": resolved.request.diagnostic,
                             "recording_estimate_bytes": recording_bytes},
                            {"resolve_and_runtime_seconds": prepared_at - started,
                             "construction_compile_run_seconds": run_finished - prepared_at,
                             "total_seconds": perf_counter() - started})


def _run_batch(jobs, plan, execution, calibrations):
    import quadrants as qd
    from . import _kernels as kernels
    from .tasks import TaskBatch, prepare

    first = jobs[0].resolved
    comp = first.target.composition
    evaluation = plan.request.evaluation
    dtype = np.dtype(plan.request.numerics.dtype)
    real = qd.f64 if dtype == np.dtype("float64") else qd.f32
    b, n, ports = len(jobs), comp.count, first.n_inputs
    frames = first.neural_frames
    tile_ticks = execution.noise_tile_frames // frames

    def upload(value, integer=False):
        host = np.asarray(value, dtype=np.int32 if integer else dtype)
        device = qd.ndarray(qd.i32 if integer else real, host.shape)
        device.from_numpy(host)
        return device

    worlds = [prepare(j.resolved.target.composition.task, _rng(j.world_seed),
                      horizon=j.resolved.horizon) for j in jobs]
    task = TaskBatch(worlds, dtype=dtype.name, warmup=evaluation.warmup)
    model = None
    if first.target.controller == "reservoir":
        module = model_module(comp.node.kind)
        constructed = {}
        initials = []
        for job in jobs:
            if job.wiring_id not in constructed:
                constructed[job.wiring_id] = module.construct(job.resolved.model_config, n, ports,
                                                             first.n_effectors,
                                                             _rng(job.construction_seed))
            initials.append(constructed[job.wiring_id])
        model = module.ModelBatch(initials, dtype=dtype.name)
        del initials, constructed
    finite = model.finite if model is not None else upload(np.ones(b), True)
    active, cursors = upload(np.ones(b), True), upload(np.zeros(b), True)
    horizons = upload([j.resolved.horizon for j in jobs], True)
    scratch = upload(np.zeros((b, ports)))
    gains = upload([j.resolved.target.composition.input_gain for j in jobs])
    blind, shuffle = upload(np.zeros(b), True), upload(np.zeros(b), True)
    permutations = []
    shuffle_seeds = {}
    for job in jobs:
        if any(i.verb == "shuffle_input" for i in job.resolved.target.interventions):
            seed = seed_for(evaluation.root_seed, evaluation.seed_partition, "input-shuffle",
                            job.resolved.target.mechanism_key, comp.node.kind, job.block, job.trial)
            shuffle_seeds[job.index] = seed
            permutations.append(_rng(seed).permutation(ports))
        else:
            permutations.append(np.arange(ports))
    permutation = upload(permutations, True)
    noise = upload(np.zeros((b, n))) if model is not None else None
    noise_tile = upload(np.zeros((execution.noise_tile_frames, b, n))) if model is not None and comp.node.kind == "falandays" else None
    tapes = [NoiseTape(_rng(j.mechanism_seed), n, execution.noise_tile_frames)
             for j in jobs] if noise_tile is not None else []
    null = first.target.controller == "reference_null"
    episodic = comp.task.kind in (*DECODABLE_TASKS, "reversal_adaptation")
    control_seeds = [seed_for(evaluation.root_seed, evaluation.seed_partition, "control",
                             j.resolved.target.mechanism_key, comp.task.kind, j.block, j.trial)
                     for j in jobs] if null else []
    control_tapes = [NoiseTape(_rng(seed), 1, tile_ticks, distribution="uniform")
                     for seed in control_seeds] if null and not episodic else []
    rounds = max(len(w.labels) for w in worlds) if episodic else tile_ticks
    controls = upload(np.stack([_rng(seed).random(rounds) for seed in control_seeds], axis=1)
                      if null and episodic else np.zeros((max(1, rounds), b)))
    randoms = upload(np.zeros(b))
    schedule = features = counts = None
    if execution.recording == "probe_events":
        schedule = upload([[w.cue_ends[0], w.response_start[0], w.response_end[0]] for w in worlds], True)
        features = upload(np.zeros((b, 3, n)))
        counts = upload(np.zeros((b, 3)), True)
    intervention_masks = {}
    for slot, job in enumerate(jobs):
        for intervention in job.resolved.target.interventions:
            key = (intervention.tick, intervention.verb)
            intervention_masks.setdefault(key, np.zeros(b, np.int32))[slot] = 1
    selected_masks = {key: upload(value, True) for key, value in intervention_masks.items()}
    mask = upload(np.zeros(b), True)
    replay = defaultdict(list)
    old_cursors, old_ticks = np.zeros(b, np.int32), np.zeros(b, np.int32)
    maximum = max(j.resolved.horizon for j in jobs)
    for start in range(0, maximum, tile_ticks):
        ticks = min(tile_ticks, maximum - start)
        if noise_tile is not None:
            host = np.zeros(noise_tile.shape, dtype=dtype)
            host[:ticks * frames] = np.stack([t.preview(ticks * frames) for t in tapes], axis=1)
            noise_tile.from_numpy(host)
        if control_tapes:
            host = np.zeros(controls.shape, dtype=dtype)
            host[:ticks] = np.stack([t.preview(ticks)[:, 0] for t in control_tapes], axis=1)
            controls.from_numpy(host)
        for offset in range(ticks):
            effectors = None
            kernels.update_active(task.done, finite, task.finite, task.ticks, horizons, active)
            for (tick, verb), selected in selected_masks.items():
                if tick == start + offset + 1:
                    kernels.selected_active(selected, active, mask)
                    if verb == "blind_input":
                        kernels.enable_flags(blind, mask)
                    elif verb == "shuffle_input":
                        kernels.enable_flags(shuffle, mask)
                    else:
                        getattr(model, verb)(mask)
            if null:
                kernels.random_frame(controls, randoms, task.current_round, offset, int(episodic))
            for frame in range(1, frames + 1):
                kernels.update_active(task.done, finite, task.finite, task.ticks, horizons, active)
                task.encode(frame, active)
                kernels.filter_finite(active, finite, task.finite)
                if model is not None:
                    assert noise is not None
                    kernels.transform_inputs(task.inputs, permutation, scratch, gains, blind, shuffle)
                    if noise_tile is not None:
                        kernels.noise_frame(noise_tile, noise, active, cursors, offset * frames + frame - 1)
                    else:
                        kernels.count_frame(active, cursors)
                    model.step(scratch, noise, active)
                    effectors = model.effectors
                else:
                    effectors = task.control(first.target.controller, randoms, active)
                    kernels.count_frame(active, cursors)
                # A numerical failure must remain inactive before a subsequent
                # neural frame can clear its model-local finite flag.
                kernels.filter_finite(active, finite, task.finite)
                task.accumulate(effectors, frame, active)
                kernels.filter_finite(active, finite, task.finite)
            if effectors is None:
                raise RuntimeError("task requires at least one neural frame")
            task.advance(effectors, active)
            kernels.filter_finite(active, finite, task.finite)
            if features is not None:
                assert model is not None and schedule is not None and counts is not None
                kernels.capture_events(model.activity, task.ticks, active, schedule, features, counts)
            if execution.recording == "replay":
                snapshot = task.snapshot()
                advanced = active.to_numpy()
                activity = model.activity.to_numpy() if model is not None else np.zeros((b, 0))
                emitted, observations = effectors.to_numpy(), task.inputs.to_numpy()
                display = ("theta", "phi", "direction", "ball_x", "ball_y", "paddle_y", "vx", "vy",
                           "width", "height", "paddle_x", "paddle_h", "paddle_min_y", "paddle_max_y",
                           "ball_r", "x", "x_dot", "theta_dot", "max_x", "pole_length", "done", "round")
                for slot, job in enumerate(jobs):
                    if advanced[slot]:
                        replay[f"{job.resolved.target.id}/{job.block}/{job.trial}"].append({
                            "tick": int(snapshot["ticks"][slot]), "activity": activity[slot].tolist(),
                            "effectors": emitted[slot].tolist(), "inputs": observations[slot].tolist(),
                            "world": {key: snapshot[key][slot].item() for key in display if key in snapshot}})
        current_cursors, current_ticks = cursors.to_numpy(), task.ticks.to_numpy()
        for slot, tape in enumerate(tapes):
            tape.consume(int(current_cursors[slot] - old_cursors[slot]))
        for slot, tape in enumerate(control_tapes):
            tape.consume(int(current_ticks[slot] - old_ticks[slot]))
        old_cursors, old_ticks = current_cursors, current_ticks
        kernels.update_active(task.done, finite, task.finite, task.ticks, horizons, active)
        if not np.any(active.to_numpy()):
            break
    snapshot, model_finite = task.snapshot(), finite.to_numpy()
    feature_values = features.to_numpy() if features is not None else None
    feature_counts = counts.to_numpy() if counts is not None else None
    results, events, probe_trials = [], [], []
    for slot, job in enumerate(jobs):
        r, target = job.resolved, job.resolved.target
        ticks = int(snapshot["ticks"][slot])
        failed = model_finite[slot] == 0 or snapshot["finite"][slot] == 0
        finished = bool(snapshot["done"][slot]) or ticks >= r.horizon
        status = "failed" if failed else "completed" if finished else "incomplete"
        value = float(snapshot["outcome"][slot])
        raw = value if status == "completed" and np.isfinite(value) else None
        if status == "completed" and raw is None:
            status = "incomplete"
        seeds = {"world": f"{job.world_seed:064x}"}
        if model is not None:
            seeds["construction"] = f"{job.construction_seed:064x}"
            if tapes:
                seeds["drive"] = f"{job.mechanism_seed:064x}"
        if null:
            seeds["control"] = f"{control_seeds[slot]:064x}"
        if job.index in shuffle_seeds:
            seeds["input_shuffle"] = f"{shuffle_seeds[job.index]:064x}"
        outcome = null_adjusted(raw, calibrations[target.id], key=r.outcome_key,
                                scoring_window=max(0, ticks - evaluation.warmup))
        results.append((job.index, TrialResult(target.id, comp.task.kind, job.block, job.trial,
                                              outcome, status, ticks, int(old_cursors[slot]),
                                              seeds["world"], job.wiring_id if model is not None else "none",
                                              seeds, "non-finite trajectory" if failed else None)))
        if feature_values is not None and status == "completed" and raw is not None:
            assert feature_counts is not None
            if not np.array_equal(feature_counts[slot], np.ones(3)):
                raise RuntimeError("probe event schedule did not emit exactly one event per point")
            ids = tuple(f"neuron/{i}" for i in range(n))
            w = worlds[slot]
            for point_index, point in enumerate(POINTS):
                events.append(ProbeEvent(target.id, comp.task.kind, job.block, job.trial, "reservoir", ids,
                                         point, int((w.cue_ends[0], w.response_start[0], w.response_end[0])[point_index]),
                                         1, int(w.labels[0]), feature_values[slot, point_index]))
            probe_trials.append(ProbeTrial(target.id, comp.task.kind, job.block, job.trial, raw,
                                           job.wiring_id, seeds["world"], digest({"node": target.composition.node,
                                                                              "config": r.model_config}),
                                           digest({"task": target.composition.task, "ports": ports,
                                                   "gain": target.composition.input_gain}),
                                           evaluation.construction_scope))
    return results, events, probe_trials, {k: tuple(v) for k, v in replay.items()}


def _interval(values, seed):
    if len(values) < 2:
        return None
    rng = _rng(seed)
    means = np.mean(np.asarray(values)[rng.integers(0, len(values), (2000, len(values)))], axis=1)
    low, high = np.quantile(means, (0.025, 0.975))
    return (float(low), float(high))


def _summarise(plan, trials, calibrations):
    result = []
    evaluation = plan.request.evaluation
    for r in plan.targets:
        rows = [t for t in trials if t.target_id == r.target.id]
        failed = sum(t.status != "completed" for t in rows)
        blocks = defaultdict(list)
        for row in rows:
            if row.status == "completed":
                blocks[row.block_id].append(row.outcome.raw)
        values = [float(np.mean(blocks[i])) for i in range(evaluation.blocks)
                  if len(blocks[i]) == evaluation.trials_per_block]
        raw = float(np.mean(values)) if not failed else None
        cal = calibrations[r.target.id]
        seed = seed_for(evaluation.root_seed, evaluation.seed_partition, "summary-bootstrap",
                        digest({"composition": r.target.composition,
                                "interventions": r.target.interventions,
                                "pairing": r.target.pairing_key,
                                "mechanism": r.target.mechanism_key}))
        adjusted = adjusted_interval(values, cal, seed=seed) if cal and not failed else None
        result.append(TargetSummary(r.target.id, r.target.composition.task.kind,
                                    null_adjusted(raw, cal, key=r.outcome_key,
                                                  scoring_window=r.horizon - evaluation.warmup),
                                    len(rows) - failed, failed, len(values),
                                    "world_blocks_conditional_on_fixed_wiring" if evaluation.construction_scope == "evaluation"
                                    else "independent_wiring_blocks" if evaluation.construction_scope == "block"
                                    else "independent_randomised_blocks",
                                    _interval(values, seed) if not failed else None, adjusted))
    return tuple(result)


def _contrasts(plan, trials):
    # Paired contrasts are restricted to identical task/world protocols. The
    # block, rather than tick or neuron, remains the inferential unit.
    result = []
    for r in plan.targets:
        target = r.target
        if target.controller != "reservoir":
            continue
        candidates = [other for other in plan.targets if other.target.id != target.id
                      and other.target.pairing_key == target.pairing_key
                      and other.target.composition.task == target.composition.task
                      and other.horizon == r.horizon
                      and (other.target.id == "baseline" if plan.request.operation == "ablate"
                           else other.target.controller == "reference_null")]
        if len(candidates) > 1:
            raise ValueError("a paired contrast requires one unambiguous reference condition")
        if not candidates:
            continue
        comparator = candidates[0]
        left = {(t.block_id, t.trial_id): t for t in trials if t.target_id == target.id}
        right = {(t.block_id, t.trial_id): t for t in trials if t.target_id == comparator.target.id}
        if set(left) != set(right) or any(t.status != "completed" for t in (*left.values(), *right.values())):
            result.append({"target_id": target.id, "reference_id": comparator.target.id, "status": "failed_pair"})
            continue
        blocks = defaultdict(list)
        for key in left:
            if left[key].world_seed != right[key].world_seed:
                raise RuntimeError("paired contrast has different world identities")
            blocks[key[0]].append(left[key].outcome.raw - right[key].outcome.raw)
        differences = [float(np.mean(blocks[i])) for i in sorted(blocks)]
        result.append({"target_id": target.id, "reference_id": comparator.target.id,
                       "status": "paired_raw", "key": r.outcome_key,
                       "estimate": float(np.mean(differences)), "block_differences": differences,
                       "interval": _interval(differences, seed_for(plan.request.evaluation.root_seed,
                                                                  plan.request.evaluation.seed_partition,
                                                                  "contrast-bootstrap", digest(target.composition),
                                                                  digest(target.interventions),
                                                                  digest(comparator.target.composition)))})
    return tuple(result)


def simulate(composition: CompositionSpec | None = None, *, evaluation: EvaluationSpec | None = None,
             numerics: NumericalPolicy | None = None, execution: ExecutionSpec | None = None,
             diagnostic=False) -> EvaluationResult:
    return execute(profile(composition or CompositionSpec(), evaluation=evaluation,
                           numerics=numerics, diagnostic=diagnostic), execution)


def calibrate(task: TaskSpec | None = None, *, root_seed=0, numerics: NumericalPolicy | None = None,
              execution: ExecutionSpec | None = None, warmup=0) -> EvaluationResult:
    composition = CompositionSpec(task=task or TaskSpec())
    plan = Plan("calibration", (EvaluationTarget("reference_null", composition, controller="reference_null"),),
                EvaluationSpec(blocks=1024, root_seed=root_seed, seed_partition="calibration", warmup=warmup),
                numerics or NumericalPolicy(), "calibrate")
    return execute(plan, execution)
