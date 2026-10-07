"""Reject precision overflow before allocating any device state."""

from collections.abc import Mapping
from dataclasses import fields, is_dataclass

import numpy as np


def validate_cast(values, dtype):
    def check(value, name):
        if is_dataclass(value):
            for item in fields(value):
                check(getattr(value, item.name), f"{name}.{item.name}")
        elif isinstance(value, Mapping):
            for key, item in value.items():
                check(item, f"{name}.{key}")
        elif isinstance(value, (int, float, np.number, np.ndarray, tuple)):
            try:
                with np.errstate(over="ignore", invalid="ignore"):
                    array = np.asarray(value, dtype=dtype)
            except (OverflowError, ValueError) as exc:
                raise ValueError(f"{name} cannot be represented as {np.dtype(dtype).name}") from exc
            if not np.all(np.isfinite(array)):
                raise ValueError(f"{name} is not finite after casting to {np.dtype(dtype).name}")

    for index, value in enumerate(values):
        check(value, f"initial[{index}]")
        for name in ("threshold_mult", "targ_min"):
            config = getattr(value, "config", None)
            if hasattr(config, name) and np.asarray(getattr(config, name), dtype=dtype) <= 0:
                raise ValueError(
                    f"{name} must remain positive after casting to {np.dtype(dtype).name}"
                )
