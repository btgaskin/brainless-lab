"""Small scheduling kernels. Kernel annotations intentionally remain live."""

import quadrants as qd


@qd.kernel(fastcache=True)
def update_active(done: qd.types.NDArray[qd.i32, 1],
                  finite: qd.types.NDArray[qd.i32, 1],
                  task_finite: qd.types.NDArray[qd.i32, 1],
                  ticks: qd.types.NDArray[qd.i32, 1],
                  horizons: qd.types.NDArray[qd.i32, 1],
                  active: qd.types.NDArray[qd.i32, 1]):
    for b in range(active.shape[0]):
        active[b] = qd.cast(done[b] == 0 and finite[b] != 0 and task_finite[b] != 0
                            and ticks[b] < horizons[b], qd.i32)


@qd.kernel(fastcache=True)
def noise_frame(tile: qd.types.NDArray[None, 3],
                noise: qd.types.NDArray[None, 2],
                active: qd.types.NDArray[qd.i32, 1],
                cursors: qd.types.NDArray[qd.i32, 1], frame: qd.i32):
    for b, n in qd.ndrange(noise.shape[0], noise.shape[1]):
        noise[b, n] = noise[b, n] * 0
        if active[b] != 0:
            noise[b, n] = tile[frame, b, n]
    for b in range(active.shape[0]):
        if active[b] != 0:
            cursors[b] += 1


@qd.kernel(fastcache=True)
def transform_inputs(inputs: qd.types.NDArray[None, 2],
                     permutation: qd.types.NDArray[qd.i32, 2],
                     scratch: qd.types.NDArray[None, 2],
                     gains: qd.types.NDArray[None, 1],
                     blind: qd.types.NDArray[qd.i32, 1],
                     shuffle: qd.types.NDArray[qd.i32, 1]):
    for b, r in qd.ndrange(inputs.shape[0], inputs.shape[1]):
        value = inputs[b, r]
        if shuffle[b] != 0:
            value = inputs[b, permutation[b, r]]
        if blind[b] != 0:
            value = value * 0
        scratch[b, r] = value * gains[b]


@qd.kernel(fastcache=True)
def selected_active(selected: qd.types.NDArray[qd.i32, 1],
                    active: qd.types.NDArray[qd.i32, 1],
                    mask: qd.types.NDArray[qd.i32, 1]):
    for b in range(active.shape[0]):
        mask[b] = selected[b] * active[b]


@qd.kernel(fastcache=True)
def enable_flags(flags: qd.types.NDArray[qd.i32, 1], mask: qd.types.NDArray[qd.i32, 1]):
    for b in range(flags.shape[0]):
        if mask[b] != 0:
            flags[b] = 1


@qd.kernel(fastcache=True)
def count_frame(active: qd.types.NDArray[qd.i32, 1], cursors: qd.types.NDArray[qd.i32, 1]):
    for b in range(active.shape[0]):
        if active[b] != 0:
            cursors[b] += 1


@qd.kernel(fastcache=True)
def random_frame(tile: qd.types.NDArray[None, 2],
                 randoms: qd.types.NDArray[None, 1],
                 rounds: qd.types.NDArray[qd.i32, 1], frame: qd.i32, episodic: qd.i32):
    for b in range(randoms.shape[0]):
        index = frame
        if episodic != 0:
            index = qd.min(rounds[b], tile.shape[0] - 1)
        randoms[b] = tile[index, b]


@qd.kernel(fastcache=True)
def filter_finite(active: qd.types.NDArray[qd.i32, 1],
                  finite: qd.types.NDArray[qd.i32, 1],
                  task_finite: qd.types.NDArray[qd.i32, 1]):
    for b in range(active.shape[0]):
        active[b] *= qd.cast(finite[b] != 0 and task_finite[b] != 0, qd.i32)


@qd.kernel(fastcache=True)
def capture_events(activity: qd.types.NDArray[None, 2],
                   ticks: qd.types.NDArray[qd.i32, 1],
                   advanced: qd.types.NDArray[qd.i32, 1],
                   schedule: qd.types.NDArray[qd.i32, 2],
                   features: qd.types.NDArray[None, 3],
                   counts: qd.types.NDArray[qd.i32, 2]):
    for b, n in qd.ndrange(activity.shape[0], activity.shape[1]):
        if advanced[b] != 0:
            t = ticks[b]
            if t == schedule[b, 0]:
                features[b, 0, n] = activity[b, n]
            if t == schedule[b, 1]:
                features[b, 1, n] = activity[b, n]
            if t > schedule[b, 1] and t <= schedule[b, 2]:
                features[b, 2, n] += activity[b, n] / (schedule[b, 2] - schedule[b, 1])
    for b in range(counts.shape[0]):
        if advanced[b] != 0:
            if ticks[b] == schedule[b, 0]:
                counts[b, 0] += 1
            if ticks[b] == schedule[b, 1]:
                counts[b, 1] += 1
            if ticks[b] == schedule[b, 2]:
                counts[b, 2] += 1
