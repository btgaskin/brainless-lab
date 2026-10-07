import os
import subprocess
import sys


def test_fresh_process_startup_and_kernel_import(tmp_path):
    env = {**os.environ, "BRAINLESSLAB_CACHE_DIR": str(tmp_path / "cache")}
    process = subprocess.run(
        [
            sys.executable,
            "-c",
            (
                "from brainlesslab.backend import initialise; "
                "from brainlesslab.specs import ExecutionSpec,NumericalPolicy; "
                "result=initialise(ExecutionSpec(cache=False),NumericalPolicy()); "
                "assert result['actual_arch'] != 'Arch.metal'; "
                "from brainlesslab import _kernels"
            ),
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert process.returncode == 0, process.stdout + process.stderr
