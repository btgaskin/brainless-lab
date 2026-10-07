"""Device-resident observations, action decoding, worlds and task outcomes."""

from collections.abc import Sequence
from dataclasses import dataclass, fields
from typing import Final

import numpy as np
import quadrants as qd

from ..models._validation import validate_cast
from ._prepare import KINDS, InitialState, validate_controller, validate_precision


@dataclass(frozen=True)
class _State:
    inputs: qd.types.NDArray[None, 2]
    physical: qd.types.NDArray[None, 2]
    votes: qd.types.NDArray[None, 2]
    last: qd.types.NDArray[None, 2]
    evidence: qd.types.NDArray[None, 2]
    ticks: qd.types.NDArray[qd.i32, 1]
    round: qd.types.NDArray[qd.i32, 1]
    done: qd.types.NDArray[qd.i32, 1]
    finite: qd.types.NDArray[qd.i32, 1]
    outcome: qd.types.NDArray[None, 1]
    total: qd.types.NDArray[None, 1]
    scored: qd.types.NDArray[qd.i32, 1]
    hits: qd.types.NDArray[qd.i32, 1]
    misses: qd.types.NDArray[qd.i32, 1]
    rally: qd.types.NDArray[qd.i32, 1]
    longest_rally: qd.types.NDArray[qd.i32, 1]
    decisions: qd.types.NDArray[qd.i32, 2]
    ties: qd.types.NDArray[qd.i32, 2]


@dataclass(frozen=True)
class _Fixed:
    kind: Final[int]
    stimuli: qd.types.NDArray[None, 3]
    lengths: qd.types.NDArray[qd.i32, 1]
    response_start: qd.types.NDArray[qd.i32, 2]
    response_end: qd.types.NDArray[qd.i32, 2]
    labels: qd.types.NDArray[qd.i32, 2]
    rounds: qd.types.NDArray[qd.i32, 1]
    reversal: qd.types.NDArray[qd.i32, 1]
    feedback: qd.types.NDArray[qd.i32, 1]
    params: qd.types.NDArray[None, 2]
    angles: qd.types.NDArray[None, 2]
    draws: qd.types.NDArray[None, 3]
    draw_lengths: qd.types.NDArray[qd.i32, 1]


@dataclass(frozen=True)
class _Controller:
    # This bundle cannot access labels, world RNG, schedules or hidden mapping.
    kind: Final[int]
    inputs: qd.types.NDArray[None, 2]
    memory: qd.types.NDArray[qd.i32, 2]
    counts: qd.types.NDArray[None, 2]
    effectors: qd.types.NDArray[None, 2]
    ticks: qd.types.NDArray[qd.i32, 1]
    round: qd.types.NDArray[qd.i32, 1]


@dataclass(frozen=True)
class _PhysicalController:
    """Easy's four declared raw observations, before spike encoding."""

    kind: Final[int]
    observations: qd.types.NDArray[None, 2]
    movement_amp: qd.types.NDArray[None, 1]
    effectors: qd.types.NDArray[None, 2]


@dataclass(frozen=True)
class _SensoryController:
    """Physical oracle limited to the same receptor values as a reservoir."""

    kind: Final[int]
    inputs: qd.types.NDArray[None, 2]
    angles: qd.types.NDArray[None, 2]
    movement_amp: qd.types.NDArray[None, 1]
    effectors: qd.types.NDArray[None, 2]


@qd.func
def _finite(value):
    return not qd.math.isnan(value) and not qd.math.isinf(value)


@qd.func
def _wrap(value, half):
    return (value + half) % (2 * half) - half


@qd.func
def _encode_world(s: _State, f: _Fixed, b: qd.i32, frame: qd.i32, enabled: qd.i32):
    for r in range(s.inputs.shape[1]):
        s.inputs[b, r] = 0
        if enabled != 0 and s.done[b] == 0 and s.finite[b] != 0:
            if qd.static(f.kind == 0):
                angle = s.physical[b, 0] * (180.0 / qd.math.pi) + f.angles[b, r]
                phi = s.physical[b, 1] * (180.0 / qd.math.pi)
                delta = _wrap(angle - phi, 180.0)
                value = f.params[b, 0]
                if qd.abs(delta) > 4:
                    value *= qd.exp(-delta * delta / 10)
                s.inputs[b, r] = value
            elif qd.static(f.kind == 1):
                dx = s.physical[b, 0] - 100
                dy = s.physical[b, 1] - s.physical[b, 2]
                bearing = qd.atan2(dy, dx) * (180.0 / qd.math.pi)
                if bearing >= -90 and bearing <= 90:
                    delta = _wrap(bearing - f.angles[b, r], 180.0)
                    if qd.abs(delta) <= 2:
                        s.inputs[b, r] = f.params[b, 0]
            elif qd.static(f.kind == 2):
                observation = r // 2
                value = s.physical[b, observation]
                count = qd.min(
                    8,
                    qd.max(
                        0, qd.cast(qd.ceil(8 * qd.abs(value) / f.params[b, observation]), qd.i32)
                    ),
                )
                slot = 0
                if (frame - 1) % 3 == 0:
                    slot = (frame - 1) // 3 + 1
                sign_bin = observation * 2
                if value > 0:
                    sign_bin += 1
                if slot > 0 and slot <= count and r == sign_bin:
                    s.inputs[b, r] = 1
            else:
                tick = s.ticks[b]
                if tick < f.lengths[b]:
                    s.inputs[b, r] = f.stimuli[b, tick, r]
                    if qd.static(f.kind == 9):
                        previous = s.round[b] - 1
                        if f.feedback[b] != 0 and previous >= 0 and f.stimuli[b, tick, 3] != 0:
                            choice = s.decisions[b, previous]
                            correct = choice == f.labels[b, previous]
                            if r == 4:
                                s.inputs[b, r] = qd.cast(choice == 1, qd.i32)
                            elif r == 5:
                                s.inputs[b, r] = qd.cast(choice == 2, qd.i32)
                            elif r == 6:
                                s.inputs[b, r] = qd.cast(correct, qd.i32)
                            elif r == 7:
                                s.inputs[b, r] = qd.cast(not correct, qd.i32)
    if enabled != 0 and s.done[b] == 0:
        for r in range(s.inputs.shape[1]):
            if not _finite(s.inputs[b, r]):
                s.finite[b] = 0


@qd.kernel(fastcache=True)
def _encode(s: _State, f: _Fixed, frame: qd.i32, active: qd.types.NDArray[qd.i32, 1]):
    for b in range(s.inputs.shape[0]):
        _encode_world(s, f, b, frame, active[b])


@qd.func
def _accumulate_world(
    s: _State,
    f: _Fixed,
    effectors: qd.types.NDArray[None, 2],
    b: qd.i32,
    frame: qd.i32,
    enabled: qd.i32,
):
    if enabled != 0 and s.done[b] == 0 and s.finite[b] != 0:
        for e in range(2):
            value = effectors[b, e]
            if not _finite(value) or value < 0 or value > 1:
                s.finite[b] = 0
            if qd.static(f.kind == 2):
                if frame == 1:
                    s.votes[b, e] = 0
                s.votes[b, e] += value
            else:
                s.last[b, e] = value


@qd.kernel(fastcache=True)
def _accumulate(
    s: _State,
    f: _Fixed,
    effectors: qd.types.NDArray[None, 2],
    frame: qd.i32,
    active: qd.types.NDArray[qd.i32, 1],
):
    for b in range(s.ticks.shape[0]):
        _accumulate_world(s, f, effectors, b, frame, active[b])


@qd.func
def _advance_world(
    s: _State,
    f: _Fixed,
    effectors: qd.types.NDArray[None, 2],
    b: qd.i32,
    enabled: qd.i32,
    warmup: qd.i32,
):
    if enabled != 0 and s.done[b] == 0 and s.finite[b] != 0:
        valid = 1
        for e in range(2):
            if not _finite(effectors[b, e]) or effectors[b, e] < 0 or effectors[b, e] > 1:
                valid = 0
        if valid == 0:
            s.finite[b] = 0
        else:
            tick = s.ticks[b]
            if qd.static(f.kind == 0):
                turn = f.params[b, 2] * (effectors[b, 0] - effectors[b, 1]) * (qd.math.pi / 180.0)
                s.physical[b, 0] = _wrap(s.physical[b, 0] + turn, qd.math.pi)
                s.physical[b, 1] = _wrap(
                    s.physical[b, 1] + s.physical[b, 2] * f.params[b, 1], qd.math.pi
                )
                if (tick + 1) % 720 == 0:
                    s.physical[b, 2] *= -1
                if tick >= warmup:
                    error = _wrap(s.physical[b, 0] - s.physical[b, 1], qd.math.pi)
                    s.total[b] += qd.cos(error)
                    s.scored[b] += 1
                    s.outcome[b] = s.total[b] / s.scored[b]
            elif qd.static(f.kind == 1):
                paddle = qd.min(
                    450, qd.max(50, s.physical[b, 2] + 100 * (effectors[b, 0] - effectors[b, 1]))
                )
                x = s.physical[b, 0] + s.physical[b, 3]
                y = s.physical[b, 1] + s.physical[b, 4]
                vx, vy = s.physical[b, 3], s.physical[b, 4]
                past = qd.cast(s.physical[b, 5], qd.i32)
                hit, miss = 0, 0
                if y <= 5:
                    y, vy = 5, qd.abs(vy)
                elif y >= 495:
                    y, vy = 495, -qd.abs(vy)
                if x >= 995:
                    x, vx, past = 995, -qd.abs(vx), 0
                if vx < 0 and past == 0 and x <= 115:
                    if qd.abs(y - paddle) <= 65:
                        x, vx, hit = 115, qd.abs(vx), 1
                    else:
                        past = 1
                if x < 0:
                    miss = 1
                    draw = qd.cast(s.physical[b, 6], qd.i32) + 1
                    if draw < f.draw_lengths[b]:
                        x, y, vx, past = 995, 1 + 498 * f.draws[b, draw, 0], -5, 0
                        vy = -5
                        if f.draws[b, draw, 1] >= 0.5:
                            vy = 5
                        s.physical[b, 6] = draw
                    else:
                        s.finite[b] = 0
                s.physical[b, 0], s.physical[b, 1], s.physical[b, 2] = x, y, paddle
                s.physical[b, 3], s.physical[b, 4], s.physical[b, 5] = vx, vy, past
                if tick >= warmup:
                    s.hits[b] += hit
                    s.misses[b] += miss
                    if miss:
                        s.rally[b] = 0
                    if hit:
                        s.rally[b] += 1
                        s.longest_rally[b] = qd.max(s.longest_rally[b], s.rally[b])
                    total = s.hits[b] + s.misses[b]
                    s.outcome[b] = 0
                    if total > 0:
                        s.outcome[b] = s.hits[b] / total
                    s.scored[b] += 1
            elif qd.static(f.kind == 2):
                force = -10.0
                if s.votes[b, 1] > s.votes[b, 0]:
                    force = 10.0
                x, xd = s.physical[b, 0], s.physical[b, 1]
                theta, td = s.physical[b, 2], s.physical[b, 3]
                cosine, sine = qd.cos(theta), qd.sin(theta)
                temp = (force + 0.1 * 0.5 * td * td * sine) / 1.1
                theta_acc = (9.8 * sine - cosine * temp) / (
                    0.5 * (4.0 / 3.0 - 0.1 * cosine * cosine / 1.1)
                )
                x_acc = temp - 0.1 * 0.5 * theta_acc * cosine / 1.1
                s.physical[b, 0] = x + 0.02 * xd
                s.physical[b, 1] = xd + 0.02 * x_acc
                s.physical[b, 2] = theta + 0.02 * td
                s.physical[b, 3] = td + 0.02 * theta_acc
                s.outcome[b] = tick + 1
                s.scored[b] = tick + 1
                if (
                    qd.abs(s.physical[b, 0]) > 2.4
                    or qd.abs(s.physical[b, 2]) > 0.2095
                    or tick + 1 >= 15000
                ):
                    s.done[b] = 1
            else:
                round_ = s.round[b]
                if round_ < f.rounds[b]:
                    if tick >= f.response_start[b, round_] and tick < f.response_end[b, round_]:
                        s.evidence[b, 0] += effectors[b, 0]
                        s.evidence[b, 1] += effectors[b, 1]
                    if tick + 1 == f.response_end[b, round_]:
                        decision = 1
                        if s.evidence[b, 1] > s.evidence[b, 0]:
                            decision = 2
                        s.decisions[b, round_] = decision
                        s.ties[b, round_] = qd.cast(s.evidence[b, 0] == s.evidence[b, 1], qd.i32)
                        s.evidence[b, 0], s.evidence[b, 1] = 0, 0
                        s.round[b] += 1
                if tick + 1 >= f.lengths[b]:
                    s.done[b] = 1
                    if qd.static(f.kind == 9):
                        correct = 0
                        for k in range(16):
                            r = f.reversal[b] - 1 + k
                            if s.decisions[b, r] == f.labels[b, r]:
                                correct += 1
                        s.outcome[b] = correct / 16.0
                    else:
                        s.outcome[b] = qd.cast(s.decisions[b, 0] == f.labels[b, 0], qd.i32)
                    s.scored[b] = f.lengths[b]
            s.ticks[b] = tick + 1
            for i in range(s.physical.shape[1]):
                if not _finite(s.physical[b, i]):
                    s.finite[b] = 0
            if s.done[b] != 0 and not _finite(s.outcome[b]):
                s.finite[b] = 0


@qd.kernel(fastcache=True)
def _advance(
    s: _State,
    f: _Fixed,
    effectors: qd.types.NDArray[None, 2],
    active: qd.types.NDArray[qd.i32, 1],
    warmup: qd.i32,
):
    for b in range(s.ticks.shape[0]):
        _advance_world(s, f, effectors, b, active[b], warmup)


# Policy names become one small declared integer interface, never float templates.
POLICIES = {
    name: i
    for i, name in enumerate(
        (
            "oracle",
            "reference_null",
            "constant_left",
            "constant_right",
            "memoryless",
            "last",
            "first",
            "context_blind",
            "irrelevant",
            "bag",
            "fixed_mapping",
        )
    )
}


@qd.func
def _control_world(
    c: _Controller,
    b: qd.i32,
    random_value,
    enabled: qd.i32,
    policy: qd.i32,
    inputs: qd.types.NDArray[None, 2],
    tick: qd.i32,
    current_round: qd.i32,
):
    # Fusion passes canonical state storage and scalar cursors explicitly.
    # A second bundle path to the same ndarray can otherwise be treated as
    # independent storage during loop load optimisation.
    if enabled != 0:
        # memory: first,last,second,context,mapping,feedback_seen,cue,
        # random_choice,random_round,observation_tick.
        choice = 1
        if policy == 1:
            if qd.static(c.kind <= 2):
                if qd.static(c.kind == 2):
                    if c.memory[b, 8] != tick:
                        c.memory[b, 7] = 1
                        if random_value >= 0.5:
                            c.memory[b, 7] = 2
                        c.memory[b, 8] = tick
                    choice = c.memory[b, 7]
                else:
                    signed = 2 * random_value - 1
                    c.effectors[b, 0] = qd.max(0, signed)
                    c.effectors[b, 1] = qd.max(0, -signed)
            else:
                round_ = current_round if qd.static(c.kind == 9) else 0
                if c.memory[b, 8] != round_:
                    c.memory[b, 7] = 1
                    if random_value >= 0.5:
                        c.memory[b, 7] = 2
                    c.memory[b, 8] = round_
                choice = c.memory[b, 7]
        else:
            # Observe once per world tick, even across 24 neural frames.
            if c.memory[b, 9] != tick:
                c.memory[b, 9] = tick
                if qd.static(c.kind == 5):
                    if inputs[b, 0] + inputs[b, 1] > 0:
                        c.memory[b, 0] = 1
                        if inputs[b, 1] > inputs[b, 0]:
                            c.memory[b, 0] = 2
                    if inputs[b, 2] + inputs[b, 3] > 0:
                        c.memory[b, 2] = 1
                        if inputs[b, 3] > inputs[b, 2]:
                            c.memory[b, 2] = 2
                    c.memory[b, 1] = c.memory[b, 2]
                elif qd.static(c.kind == 7):
                    if inputs[b, 0] + inputs[b, 1] > 0:
                        c.memory[b, 3] = 1
                        if inputs[b, 1] > inputs[b, 0]:
                            c.memory[b, 3] = 2
                    c.counts[b, 0] += inputs[b, 2] - inputs[b, 3]
                    c.counts[b, 1] += inputs[b, 4] - inputs[b, 5]
                    stream = c.memory[b, 3]
                    if policy == 7:
                        stream = 1
                    elif policy == 8:
                        stream = 3 - stream
                    offset = stream * 2
                    if inputs[b, offset] + inputs[b, offset + 1] > 0:
                        c.memory[b, 1] = 1
                        if inputs[b, offset + 1] > inputs[b, offset]:
                            c.memory[b, 1] = 2
                        if c.memory[b, 0] == 0:
                            c.memory[b, 0] = c.memory[b, 1]
                elif qd.static(c.kind == 9):
                    if inputs[b, 3] > 0:
                        if c.memory[b, 5] == 0 and inputs[b, 4] + inputs[b, 5] > 0 and policy == 0:
                            chosen = 1
                            if inputs[b, 5] > inputs[b, 4]:
                                chosen = 2
                            correct_choice = chosen
                            if inputs[b, 6] <= inputs[b, 7]:
                                correct_choice = 3 - chosen
                            c.memory[b, 4] = qd.cast(correct_choice != c.memory[b, 6], qd.i32)
                        c.memory[b, 5] = 1
                    else:
                        c.memory[b, 5] = 0
                        if inputs[b, 0] + inputs[b, 1] > 0:
                            c.memory[b, 6] = 1
                            if inputs[b, 1] > inputs[b, 0]:
                                c.memory[b, 6] = 2
                else:
                    if inputs[b, 0] + inputs[b, 1] > 0:
                        c.memory[b, 1] = 1
                        if inputs[b, 1] > inputs[b, 0]:
                            c.memory[b, 1] = 2
                        if c.memory[b, 0] == 0:
                            c.memory[b, 0] = c.memory[b, 1]
                    if qd.static(c.kind == 6):
                        c.counts[b, 0] += inputs[b, 0] - inputs[b, 1]
                    elif qd.static(c.kind == 8):
                        c.counts[b, 0] += inputs[b, 0]
                        c.counts[b, 1] += inputs[b, 1]
                        if inputs[b, 0] + inputs[b, 1] == 0 and inputs[b, 2] > 0:
                            c.memory[b, 1] = 1
            choice = qd.max(1, c.memory[b, 0])
            if qd.static(c.kind == 5):
                choice = 1
                if c.memory[b, 0] != c.memory[b, 2]:
                    choice = 2
            elif qd.static(c.kind == 6):
                choice = 1
                if c.counts[b, 0] < 0:
                    choice = 2
            elif qd.static(c.kind == 7):
                stream = c.memory[b, 3]
                if policy == 7:
                    stream = 1
                elif policy == 8:
                    stream = 3 - stream
                choice = 1
                if c.counts[b, stream - 1] < 0:
                    choice = 2
            elif qd.static(c.kind == 8):
                if policy == 9:
                    choice = 1
                    if c.counts[b, 1] > c.counts[b, 0]:
                        choice = 2
            elif qd.static(c.kind == 9):
                choice = c.memory[b, 6]
                if c.memory[b, 4] != 0:
                    choice = 3 - choice
            if policy == 2:
                choice = 1
            elif policy == 3:
                choice = 2
            elif policy == 4:
                choice = 1
                if qd.static(c.kind == 5):
                    a, d = 1, 1
                    if inputs[b, 1] > inputs[b, 0]:
                        a = 2
                    if inputs[b, 3] > inputs[b, 2]:
                        d = 2
                    if a != d:
                        choice = 2
                else:
                    if inputs[b, 1] > inputs[b, 0]:
                        choice = 2
            elif policy == 5:
                choice = c.memory[b, 1]
            elif policy == 6:
                choice = qd.max(1, c.memory[b, 0])
        if qd.static(c.kind >= 2):
            c.effectors[b, 0] = qd.cast(choice == 1, qd.i32)
            c.effectors[b, 1] = qd.cast(choice == 2, qd.i32)
        elif policy != 1:
            c.effectors[b, 0] = qd.cast(choice == 1, qd.i32)
            c.effectors[b, 1] = qd.cast(choice == 2, qd.i32)


@qd.kernel(fastcache=True)
def _control(
    c: _Controller,
    randoms: qd.types.NDArray[None, 1],
    active: qd.types.NDArray[qd.i32, 1],
    policy: qd.i32,
):
    for b in range(c.inputs.shape[0]):
        _control_world(c, b, randoms[b], active[b], policy, c.inputs, c.ticks[b], c.round[b])


@qd.func
def _physical_observations_world(s: _State, c: _PhysicalController, b: qd.i32, enabled: qd.i32):
    if enabled != 0:
        for i in range(4):
            c.observations[b, i] = s.physical[b, i]


@qd.kernel(fastcache=True)
def _physical_observations(s: _State, c: _PhysicalController, active: qd.types.NDArray[qd.i32, 1]):
    for b in range(c.observations.shape[0]):
        _physical_observations_world(s, c, b, active[b])


@qd.func
def _physical_reference_world(
    c: _PhysicalController, b: qd.i32, enabled: qd.i32, effectors: qd.types.NDArray[None, 2]
):
    if enabled != 0:
        command = (
            80 * _wrap(c.observations[b, 2], qd.math.pi)
            + 18 * c.observations[b, 3]
            + c.observations[b, 0]
            + 2 * c.observations[b, 1]
        )
        turn = -1.0
        if command < 0:
            turn = 1.0
        effectors[b, 0] = qd.max(0, turn)
        effectors[b, 1] = qd.max(0, -turn)


@qd.kernel(fastcache=True)
def _physical_reference(c: _PhysicalController, active: qd.types.NDArray[qd.i32, 1]):
    for b in range(c.effectors.shape[0]):
        _physical_reference_world(c, b, active[b], c.effectors)


@qd.func
def _sensory_reference_world(
    c: _SensoryController,
    b: qd.i32,
    enabled: qd.i32,
    inputs: qd.types.NDArray[None, 2],
    effectors: qd.types.NDArray[None, 2],
):
    # The maximum receptor response determines a coarse relative bearing.
    # This has the same limited field of view as the ordinary controller.
    # Its score is a reference-policy result, never an analytic ceiling.
    if enabled != 0:
        best, angle = 0.0, 0.0
        for r in range(inputs.shape[1]):
            if inputs[b, r] > best:
                best, angle = inputs[b, r], c.angles[b, r]
        turn = 0.0
        if best > 0:
            if qd.static(c.kind == 0):
                turn = angle / c.movement_amp[b]
            else:
                turn = qd.sin(angle * (qd.math.pi / 180.0))
        turn = qd.max(-1, qd.min(1, turn))
        effectors[b, 0] = qd.max(0, turn)
        effectors[b, 1] = qd.max(0, -turn)


@qd.kernel(fastcache=True)
def _sensory_reference(c: _SensoryController, active: qd.types.NDArray[qd.i32, 1]):
    for b in range(c.inputs.shape[0]):
        _sensory_reference_world(c, b, active[b], c.inputs, c.effectors)


@qd.kernel(fastcache=True)
def _run_control(
    s: _State,
    f: _Fixed,
    c: _Controller,
    physical: _PhysicalController,
    sensory: _SensoryController,
    uniform_tile: qd.types.NDArray[None, 2],
    horizons: qd.types.NDArray[qd.i32, 1],
    guard: qd.types.NDArray[qd.i32, 1],
    policy: qd.i32,
    tile_ticks: qd.i32,
    warmup: qd.i32,
):
    # Each world owns its complete serial tick/frame sequence. No sums or
    # state updates cross world boundaries, and no floating atomics are used.
    for b in range(s.ticks.shape[0]):
        for offset in range(tile_ticks):
            guard[b] = qd.cast(
                guard[b] != 0 and s.done[b] == 0 and s.finite[b] != 0 and s.ticks[b] < horizons[b],
                qd.i32,
            )
            index = offset
            if qd.static(f.kind >= 3):
                index = qd.min(s.round[b], uniform_tile.shape[0] - 1)
            random_value = uniform_tile[index, b]
            frames = 1
            if qd.static(f.kind == 2):
                frames = 24
            for frame0 in range(frames):
                guard[b] *= qd.cast(s.finite[b] != 0, qd.i32)
                _encode_world(s, f, b, frame0 + 1, guard[b])
                guard[b] *= qd.cast(s.finite[b] != 0, qd.i32)
                if policy == 0:
                    if qd.static(f.kind <= 1):
                        _sensory_reference_world(sensory, b, guard[b], s.inputs, c.effectors)
                    elif qd.static(f.kind == 2):
                        _physical_observations_world(s, physical, b, guard[b])
                        _physical_reference_world(physical, b, guard[b], c.effectors)
                    else:
                        _control_world(
                            c, b, random_value, guard[b], policy, s.inputs, s.ticks[b], s.round[b]
                        )
                else:
                    _control_world(
                        c, b, random_value, guard[b], policy, s.inputs, s.ticks[b], s.round[b]
                    )
                _accumulate_world(s, f, c.effectors, b, frame0 + 1, guard[b])
                guard[b] *= qd.cast(s.finite[b] != 0, qd.i32)
            _advance_world(s, f, c.effectors, b, guard[b], warmup)
            guard[b] *= qd.cast(s.finite[b] != 0, qd.i32)


class TaskBatch:
    def __init__(self, initials: Sequence[InitialState], dtype="float64", warmup=0):
        initials = tuple(initials)
        if not initials:
            raise ValueError("a task batch needs at least one world")
        first = initials[0]
        if any(
            v.spec.kind != first.spec.kind or v.definition.n_inputs != first.definition.n_inputs
            for v in initials
        ):
            raise ValueError("one cohort needs the same task family and port widths")
        if isinstance(warmup, bool) or not isinstance(warmup, int) or warmup < 0:
            raise ValueError("warmup must be a nonnegative integer")
        if warmup and (first.definition.is_probe or first.spec.kind == "cartpole_plank_easy"):
            raise ValueError("probes and Plank CartPole require warmup=0")
        self.initials, self.definition = initials, first.definition
        self.kind, self.batch_size, self.warmup = first.spec.kind, len(initials), warmup
        self.dtype = np.dtype(dtype)
        if self.dtype not in (np.dtype("float64"), np.dtype("float32")):
            raise ValueError("dtype must be float64 or float32")
        self._real = qd.f64 if self.dtype == np.dtype("float64") else qd.f32
        validate_cast(initials, self.dtype)
        validate_precision(initials, self.dtype)
        B, R = self.batch_size, self.definition.n_inputs
        params, angles = np.zeros((B, 4)), np.zeros((B, R))
        for b, v in enumerate(initials):
            o = v.options
            if self.kind == "tracking":
                params[b] = [o["sensory_gain"], o["stim_speed_rad"], o["movement_amp"], 0]
                angles[b] = [
                    eye + offset
                    for eye in (o["eye_offset_deg"], -o["eye_offset_deg"])
                    for offset in o["sensor_offsets_deg"]
                ]
            elif self.kind == "pong":
                params[b, 0], angles[b] = o["sensory_gain"], np.arange(-90, 91, 4)
            elif self.kind == "cartpole_plank_easy":
                params[b] = [2.4, 2.0, 0.2095, 2.0]
        validate_cast((params, angles), self.dtype)

        def upload(values, integer=False):
            host = np.array(values, dtype=np.int32 if integer else self.dtype, order="C", copy=True)
            array = qd.ndarray(qd.i32 if integer else self._real, host.shape)
            array.from_numpy(host)
            return array

        def zeros(shape, integer=False):
            return upload(np.zeros(shape), integer)

        B, R = self.batch_size, self.definition.n_inputs
        max_rounds = max(1, max(v.labels.size for v in initials))
        max_length = max(v.stimuli.shape[0] for v in initials)
        max_draws = max(v.draws.shape[0] for v in initials)
        stimuli = np.zeros((B, max_length, R))
        draws = np.zeros((B, max_draws, 2))
        starts, ends, labels = (np.zeros((B, max_rounds), dtype=np.int32) for _ in range(3))
        for b, initial in enumerate(initials):
            stimuli[b, : initial.stimuli.shape[0]] = initial.stimuli
            draws[b, : initial.draws.shape[0]] = initial.draws
            for host, name in (
                (starts, "response_start"),
                (ends, "response_end"),
                (labels, "labels"),
            ):
                values = getattr(initial, name)
                host[b, : values.size] = values
        self._state = _State(
            zeros((B, R)),
            upload([v.physical for v in initials]),
            zeros((B, 2)),
            zeros((B, 2)),
            zeros((B, 2)),
            zeros(B, True),
            zeros(B, True),
            zeros(B, True),
            upload(np.ones(B), True),
            upload(np.full(B, np.nan if self.definition.is_probe else 0.0)),
            zeros(B),
            zeros(B, True),
            zeros(B, True),
            zeros(B, True),
            zeros(B, True),
            zeros(B, True),
            zeros((B, max_rounds), True),
            zeros((B, max_rounds), True),
        )
        self._fixed = _Fixed(
            KINDS[self.kind],
            upload(stimuli),
            upload([v.stimuli.shape[0] for v in initials], True),
            upload(starts, True),
            upload(ends, True),
            upload(labels, True),
            upload([v.labels.size for v in initials], True),
            upload([v.metadata.get("reversal_round", 0) for v in initials], True),
            upload([v.options.get("feedback_mode") == "visible" for v in initials], True),
            upload(params),
            upload(angles),
            upload(draws),
            upload([v.draws.shape[0] for v in initials], True),
        )
        memory = np.zeros((B, 10), dtype=np.int32)
        memory[:, [1, 2, 3, 6, 7]] = 1
        memory[:, [8, 9]] = -1
        self._controller = _Controller(
            KINDS[self.kind],
            self._state.inputs,
            upload(memory, True),
            zeros((B, 2)),
            zeros((B, 2)),
            self._state.ticks,
            self._state.round,
        )
        self._physical_controller = _PhysicalController(
            KINDS[self.kind],
            zeros((B, 4)),
            upload([v.options.get("movement_amp", 1) for v in initials]),
            self._controller.effectors,
        )
        self._sensory_controller = _SensoryController(
            KINDS[self.kind],
            self.inputs,
            self._fixed.angles,
            self._physical_controller.movement_amp,
            self._controller.effectors,
        )
        allowed = set()
        for policy in POLICIES:
            try:
                validate_controller(first.spec, policy)
            except ValueError:
                continue
            allowed.add(policy)
        self._allowed_controls = frozenset(allowed)
        self._all_active = upload(np.ones(B), True)

    @property
    def inputs(self):
        return self._state.inputs

    @property
    def done(self):
        return self._state.done

    @property
    def ticks(self):
        return self._state.ticks

    @property
    def current_round(self):
        return self._state.round

    @property
    def outcome(self):
        return self._state.outcome

    @property
    def finite(self):
        return self._state.finite

    def _check(self, active):
        if active.shape != (self.batch_size,) or active.dtype != qd.i32:
            raise ValueError("active must be an int32 array matching the cohort")

    def _effectors(self, effectors):
        if effectors.shape != (self.batch_size, 2) or effectors.dtype != self._real:
            raise ValueError("effectors must match task batch width and dtype")

    def encode(self, frame, active):
        self._check(active)
        if not isinstance(frame, int) or not 1 <= frame <= self.definition.neural_frames:
            raise ValueError("frame is one-based within the declared neural cycle")
        _encode(self._state, self._fixed, frame, active)

    def accumulate(self, effectors, frame, active):
        self._check(active)
        self._effectors(effectors)
        if not isinstance(frame, int) or not 1 <= frame <= self.definition.neural_frames:
            raise ValueError("frame is one-based within the declared neural cycle")
        _accumulate(self._state, self._fixed, effectors, frame, active)

    def advance(self, effectors, active):
        self._check(active)
        self._effectors(effectors)
        _advance(self._state, self._fixed, effectors, active, self.warmup)

    def control(self, policy, randoms, active=None):
        if policy == "reference_nullblindpolicy":
            policy = "reference_null"
        if policy not in self._allowed_controls:
            raise ValueError(f"policy {policy!r} is not defined for {self.kind}")
        if randoms.shape != (self.batch_size,) or randoms.dtype != self._real:
            raise ValueError("randoms must match batch width and dtype")
        if active is None:
            active = self._all_active
        self._check(active)
        if policy == "oracle" and self.kind in ("tracking", "pong"):
            _sensory_reference(self._sensory_controller, active)
        elif policy == "oracle" and self.kind == "cartpole_plank_easy":
            _physical_observations(self._state, self._physical_controller, active)
            _physical_reference(self._physical_controller, active)
        else:
            _control(self._controller, randoms, active, POLICIES[policy])
        return self._controller.effectors

    def run_control(self, policy, uniform_tile, horizons, active_guard=None, tile_ticks=None):
        """Advance a bounded control-only tile without per-frame host dispatch.

        ``uniform_tile`` is a device array shaped (draws, worlds). Physical
        policies use one draw per tile tick, held across neural frames. Probe
        policies use one draw per round from the complete episode table.
        ``horizons`` contains absolute world-tick limits. ``active_guard`` is
        an optional input/output mask; failures remain disabled within a tile.
        """
        if policy == "reference_nullblindpolicy":
            policy = "reference_null"
        if policy not in self._allowed_controls:
            raise ValueError(f"policy {policy!r} is not defined for {self.kind}")
        if (
            len(uniform_tile.shape) != 2
            or uniform_tile.shape[0] < 1
            or uniform_tile.shape[1] != self.batch_size
            or uniform_tile.dtype != self._real
        ):
            raise ValueError("uniform_tile must match batch width and dtype")
        if horizons.shape != (self.batch_size,) or horizons.dtype != qd.i32:
            raise ValueError("horizons must be an int32 array matching the cohort")
        if tile_ticks is None:
            tile_ticks = uniform_tile.shape[0]
        if isinstance(tile_ticks, bool) or not isinstance(tile_ticks, int) or tile_ticks < 1:
            raise ValueError("tile_ticks must be a positive integer")
        required = (
            max(v.labels.size for v in self.initials) if self.definition.is_probe else tile_ticks
        )
        if uniform_tile.shape[0] < required:
            raise ValueError("uniform_tile needs all probe rounds or all physical tile ticks")
        if active_guard is None:
            active_guard = self._all_active
        self._check(active_guard)
        _run_control(
            self._state,
            self._fixed,
            self._controller,
            self._physical_controller,
            self._sensory_controller,
            uniform_tile,
            horizons,
            active_guard,
            POLICIES[policy],
            tile_ticks,
            self.warmup,
        )
        return self._controller.effectors

    def snapshot(self):
        result = {
            field.name: np.array(getattr(self._state, field.name).to_numpy(), copy=True)
            for field in fields(_State)
        }
        result["tick"] = result["ticks"].copy()
        result["raw_outcome"] = result["outcome"].copy()
        state = result["physical"]
        if self.kind == "tracking":
            for i, name in enumerate(("theta", "phi", "direction")):
                result[name] = state[:, i].copy()
        elif self.kind == "pong":
            for i, name in enumerate(("ball_x", "ball_y", "paddle_y", "vx", "vy")):
                result[name] = state[:, i].copy()
            for name, value in dict(
                width=1000,
                height=500,
                paddle_x=100,
                paddle_h=100,
                paddle_min_y=50,
                paddle_max_y=450,
                ball_r=15,
            ).items():
                result[name] = np.full(self.batch_size, value, dtype=self.dtype)
        elif self.kind == "cartpole_plank_easy":
            for i, name in enumerate(("x", "x_dot", "theta", "theta_dot")):
                result[name] = state[:, i].copy()
            result["max_x"] = np.full(self.batch_size, 2.4, dtype=self.dtype)
            result["pole_length"] = np.full(self.batch_size, 0.5, dtype=self.dtype)
        return result
