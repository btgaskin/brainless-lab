"""Generate a pycma diagonal-CMA trace for BrainlessLab SepCMA tests."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Optional

import cma
import numpy as np


def sphere(x):
    x = np.asarray(x, dtype=float)
    return float(np.sum(x * x))


def default_x0(dim: int) -> np.ndarray:
    if dim == 5:
        return np.array([0.8, -0.6, 0.4, -0.2, 0.1], dtype=float)
    return np.linspace(0.8, -0.4, dim, dtype=float)


def diagonal_cscale(es) -> Optional[np.ndarray]:
    try:
        scaling = np.asarray(getattr(es.sigma_vec, "scaling", 1.0), dtype=float)
        cmat = np.asarray(es.sm.C, dtype=float)
        cdiag = cmat if cmat.ndim == 1 else np.diag(cmat)
        if scaling.ndim == 0:
            scaling = np.full_like(cdiag, float(scaling), dtype=float)
        return scaling * np.sqrt(cdiag)
    except Exception:
        return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dim", type=int, default=5)
    parser.add_argument("--generations", type=int, default=10)
    parser.add_argument("--popsize", type=int, default=8)
    parser.add_argument("--sigma0", type=float, default=0.7)
    parser.add_argument("--seed", type=int, default=12)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()

    here = Path(__file__).resolve()
    repo_root = here.parents[2]
    output = args.output or repo_root / "test" / "fixtures" / "cma_sphere_trace.npz"
    output.parent.mkdir(parents=True, exist_ok=True)

    x0 = default_x0(args.dim)
    es = cma.CMAEvolutionStrategy(
        x0,
        args.sigma0,
        {
            "CMA_diagonal": True,
            "popsize": args.popsize,
            "seed": args.seed,
            "verbose": -9,
        },
    )

    populations = []
    losses_by_gen = []
    means = []
    sigmas = []
    cscales = []
    cscale_available = True

    for _ in range(args.generations):
        X = es.ask()
        losses = [sphere(x) for x in X]
        es.tell(X, losses)
        populations.append(np.asarray(X, dtype=float))
        losses_by_gen.append(np.asarray(losses, dtype=float))
        means.append(np.asarray(es.mean, dtype=float).copy())
        sigmas.append(float(es.sigma))
        cscale = diagonal_cscale(es)
        if cscale is None:
            cscale_available = False
        elif cscale_available:
            cscales.append(np.asarray(cscale, dtype=float).copy())

    payload = dict(
        x0=x0,
        sigma0=np.array(args.sigma0, dtype=float),
        popsize=np.array(args.popsize, dtype=np.int64),
        seed=np.array(args.seed, dtype=np.int64),
        X=np.asarray(populations, dtype=float),
        losses=np.asarray(losses_by_gen, dtype=float),
        mean=np.asarray(means, dtype=float),
        sigma=np.asarray(sigmas, dtype=float),
    )
    if cscale_available and len(cscales) == args.generations:
        payload["cscale"] = np.asarray(cscales, dtype=float)

    np.savez(output, **payload)


if __name__ == "__main__":
    main()
