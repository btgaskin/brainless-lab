"""Small scheduling kernels. Kernel annotations intentionally remain live."""

import quadrants as qd


@qd.kernel(fastcache=True)
def update_active(done: qd.types.NDArray[qd.i32, 1],
                  finite: qd.types.NDArray[qd.i32, 1],
                  active: qd.types.NDArray[qd.i32, 1]):
    for b in range(active.shape[0]):
        active[b] = qd.cast(done[b] == 0 and finite[b] != 0, qd.i32)


@qd.kernel(fastcache=True)
def noise_frame(tile: qd.types.NDArray[qd.Any, 3],
                noise: qd.types.NDArray[qd.Any, 2],
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
def transform_inputs(inputs: qd.types.NDArray[qd.Any, 2],
                     permutation: qd.types.NDArray[qd.i32, 2],
                     scratch: qd.types.NDArray[qd.Any, 2],
                     gains: qd.types.NDArray[qd.Any, 1],
                     blind: qd.i32, shuffle: qd.i32):
    for b, r in qd.ndrange(inputs.shape[0], inputs.shape[1]):
        value = inputs[b, r]
        if shuffle != 0:
            value = inputs[b, permutation[b, r]]
        if blind != 0:
            value = value * 0
        scratch[b, r] = value * gains[b]
