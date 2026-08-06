import type { Rng } from './rng';
import type { FalandaysParams } from './types';

/**
 * Bernoulli connectivity mask, `rows x cols`, row-major flat array
 * (`mask[i*cols+j]` = edge from row-index i to column-index j exists).
 * `excludeSelfLoops` matches Falandays.jl's recurrent mask (no self-connections,
 * `link_p` default 0.1) — not meaningful for the rectangular input/output masks.
 */
export function bernoulliMask(rows: number, cols: number, p: number, rng: Rng, excludeSelfLoops = false): Uint8Array {
  const mask = new Uint8Array(rows * cols);
  // Julia fills matrices column-first and consumes diagonal draws before
  // clearing recurrent self-loops. Preserve that construction order here.
  for (let j = 0; j < cols; j++) {
    for (let i = 0; i < rows; i++) {
      if (rng.uniform() < p) mask[i * cols + j] = 1;
    }
  }
  if (excludeSelfLoops && rows === cols) {
    for (let i = 0; i < rows; i++) mask[i * cols + i] = 0;
  }
  return mask;
}

/**
 * Guarantees every reservoir node has at least one incoming edge (recurrent or
 * input) — mirrors `_ensure_unsigned_degree!` in Axes.jl, which exists because a
 * zero-in-degree node can never receive current and would sit permanently dead.
 */
export function ensureNodeInDegree(
  recurrentMask: Uint8Array,
  inputMask: Uint8Array,
  nNodes: number,
  nReceptors: number,
  rng: Rng,
): void {
  for (let node = 0; node < nNodes; node++) {
    let degree = 0;
    for (let i = 0; i < nNodes; i++) if (recurrentMask[i * nNodes + node]) degree++;
    for (let i = 0; i < nReceptors; i++) if (inputMask[i * nNodes + node]) degree++;
    if (degree === 0) {
      inputMask[rng.int(nReceptors) * nNodes + node] = 1;
    }
  }
}

/** Guarantees every effector has at least one connected node — mirrors `_ensure_output_mask!`. */
export function ensureEffectorInDegree(outputMask: Uint8Array, nNodes: number, nEffectors: number, rng: Rng): void {
  for (let k = 0; k < nEffectors; k++) {
    let any = false;
    for (let i = 0; i < nNodes; i++) {
      if (outputMask[i * nEffectors + k]) {
        any = true;
        break;
      }
    }
    if (!any) outputMask[rng.int(nNodes) * nEffectors + k] = 1;
  }
}

/** Authors' per-task recurrent weight init, masked to the connectivity graph. */
export function initWeights(
  recurrentMask: Uint8Array,
  nNodes: number,
  params: Pick<FalandaysParams, 'inputWeight' | 'weightInitMode' | 'weightInitStd'>,
  rng: Rng,
): Float64Array {
  const w = new Float64Array(nNodes * nNodes);
  if (params.weightInitMode === 'pongMixed') {
    const inhibitory = new Uint8Array(nNodes * nNodes);
    const negativeWeights = new Float64Array(nNodes * nNodes);
    for (let j = 0; j < nNodes; j++) {
      for (let i = 0; i < nNodes; i++) inhibitory[i * nNodes + j] = rng.uniform() < 0.25 ? 1 : 0;
    }
    for (let j = 0; j < nNodes; j++) {
      for (let i = 0; i < nNodes; i++) negativeWeights[i * nNodes + j] = -1.0 + 0.1 * rng.gaussian();
    }
    for (let j = 0; j < nNodes; j++) {
      for (let i = 0; i < nNodes; i++) {
        const idx = i * nNodes + j;
        const nearZero = 0.2 * rng.gaussian();
        if (recurrentMask[idx]) w[idx] = inhibitory[idx] ? negativeWeights[idx] : nearZero;
      }
    }
    return w;
  }

  for (let j = 0; j < nNodes; j++) {
    for (let i = 0; i < nNodes; i++) {
      const idx = i * nNodes + j;
      const gaussian = rng.gaussian();
      if (!recurrentMask[idx]) continue;
      w[idx] = params.weightInitMode === 'excitatory'
        ? params.inputWeight + 0.1 * gaussian
        : params.weightInitStd * gaussian;
    }
  }
  return w;
}
