"""Versioned random identities and bounded tapes independent of physical slots."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field

import numpy as np

SCHEME = "philox-host-v1"


def seed_for(root_seed: int, partition: str, stream: str, *keys: str | int) -> int:
    payload = json.dumps(
        [SCHEME, root_seed, partition, stream, [[type(k).__name__, k] for k in keys]],
        ensure_ascii=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return int.from_bytes(hashlib.sha256(payload).digest(), "little")


def generator(root_seed: int, partition: str, stream: str, *keys: str | int) -> np.random.Generator:
    return np.random.Generator(np.random.Philox(seed_for(root_seed, partition, stream, *keys)))


@dataclass
class NoiseTape:
    """Prefetch changes no logical cursor; consumed frame sequences are stable."""

    rng: np.random.Generator
    width: int
    tile_frames: int = 64
    consumed: int = 0
    distribution: str = "normal"
    _tile: np.ndarray = field(default_factory=lambda: np.empty((0, 0)), repr=False)
    _offset: int = 0

    def __post_init__(self) -> None:
        if self.width < 1 or self.tile_frames < 1:
            raise ValueError("noise width and tile_frames must be positive")
        if self.distribution not in ("normal", "uniform"):
            raise ValueError("unsupported random tape distribution")
        self._tile = np.empty((0, self.width))

    def frame(self) -> np.ndarray:
        result = self.preview(1)[0]
        self.consume(1)
        return result

    def preview(self, count: int) -> np.ndarray:
        """Return a future prefix without advancing logical consumption."""
        if count < 1 or count > self.tile_frames:
            raise ValueError("preview must fit within one configured tile")
        remaining = self._tile[self._offset :]
        if len(remaining) < count:
            shape = (count - len(remaining), self.width)
            fresh = (
                self.rng.standard_normal(shape)
                if self.distribution == "normal"
                else self.rng.random(shape)
            )
            self._tile = np.concatenate((remaining, fresh), axis=0)
            self._offset = 0
        return self._tile[self._offset : self._offset + count]

    def consume(self, count: int) -> None:
        if count < 0 or count > len(self._tile) - self._offset:
            raise ValueError("consumption exceeds prepared noise")
        self._offset += count
        self.consumed += count

    def state(self) -> dict[str, object]:
        return {
            "scheme": SCHEME,
            "consumed_frames": self.consumed,
            "generator": self.rng.bit_generator.state,
            "unused_tail": self._tile[self._offset :].copy(),
        }
