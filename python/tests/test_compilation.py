"""Qualification of a cache boundary, without treating cache hits as test proof."""

import os
import subprocess
import sys

SOURCE = """
import numpy as np
import quadrants as qd
qd.init(arch=qd.cpu, default_fp=qd.f64, fast_math=False, enable_fallback=False,
        cpu_max_num_threads=1, raise_on_templated_floats=True,
        offline_cache_file_path=CACHE)
@qd.func
def helper(value):
    return value + OFFSET
@qd.kernel(fastcache=True)
def run(output: qd.types.NDArray[None, 1]):
    for i in range(output.shape[0]):
        output[i] = helper(output[i])
array = qd.ndarray(qd.f64, (2,))
array.from_numpy(np.zeros(2))
run(array)
np.testing.assert_array_equal(array.to_numpy(), [OFFSET, OFFSET])
print("HELPER_VALUE=" + str(array.to_numpy()[0]))
"""


def test_fastcache_tracks_changed_helper_source(tmp_path):
    cache = tmp_path / "cache"
    script = tmp_path / "case.py"
    for value in (1, 1, 2):
        script.write_text(SOURCE.replace("CACHE", repr(str(cache))).replace("OFFSET", str(value)))
        run = subprocess.run(
            [sys.executable, str(script)],
            capture_output=True,
            text=True,
            env=os.environ | {"PYTHONDONTWRITEBYTECODE": "1"},
        )
        assert run.returncode == 0, run.stderr + run.stdout
        assert f"HELPER_VALUE={value}.0" in run.stdout
