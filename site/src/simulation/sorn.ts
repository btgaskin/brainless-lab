import { Rng } from './rng';
import { bernoulliMask } from './wiring';
import type { SornParams } from './types';

function ensureEachRow(mask: Uint8Array, rows: number, cols: number, rng: Rng, noSelf = false): void {
  if (cols === 0) return;
  for (let row = 0; row < rows; row++) {
    let connected = false;
    const offset = row * cols;
    for (let col = 0; col < cols; col++) {
      if (mask[offset + col]) {
        connected = true;
        break;
      }
    }
    if (connected) continue;

    if (noSelf && rows === cols) {
      if (cols <= 1) continue;
      let col = rng.int(cols - 1);
      if (col >= row) col += 1;
      mask[offset + col] = 1;
    } else {
      mask[offset + rng.int(cols)] = 1;
    }
  }
}

function ensureEachColumn(mask: Uint8Array, rows: number, cols: number, rng: Rng): void {
  if (rows === 0) return;
  for (let col = 0; col < cols; col++) {
    let connected = false;
    for (let row = 0; row < rows; row++) {
      if (mask[row * cols + col]) {
        connected = true;
        break;
      }
    }
    if (!connected) mask[rng.int(rows) * cols + col] = 1;
  }
}

function rowNormalisedWeights(
  mask: Uint8Array,
  rows: number,
  cols: number,
  target: number,
  rng: Rng,
): Float64Array {
  const weights = new Float64Array(rows * cols);
  if (target === 0) return weights;

  for (let row = 0; row < rows; row++) {
    const offset = row * cols;
    let total = 0;
    for (let col = 0; col < cols; col++) {
      const index = offset + col;
      if (!mask[index]) continue;
      const value = rng.uniform();
      weights[index] = value;
      total += value;
    }
    if (total === 0) continue;
    const scale = target / total;
    for (let col = 0; col < cols; col++) weights[offset + col] *= scale;
  }
  return weights;
}

/**
 * Browser reimplementation of the registered experimental SORN node.
 *
 * The update order follows `src/nodes/SORN.jl`: binary excitatory and
 * inhibitory dynamics, E-to-E STDP, intrinsic threshold plasticity, then
 * incoming E-to-E synaptic normalisation. The browser uses its own seeded
 * PRNG, so this is an illustrative deterministic port rather than a Julia
 * trajectory fixture.
 */
export class SornReservoir {
  readonly nNodes: number;
  readonly nReceptors: number;
  readonly nEffectors: number;
  readonly nInhibitory: number;
  readonly params: SornParams;

  private readonly eeMask: Uint8Array;
  private readonly outputMask: Uint8Array;
  private readonly cE: Float64Array;
  private readonly wEi: Float64Array;
  private readonly wIe: Float64Array;
  private readonly wEu: Float64Array;
  private readonly tI: Float64Array;
  private readonly x: Float64Array;
  private readonly y: Float64Array;
  private readonly prevX: Float64Array;
  private readonly prevY: Float64Array;
  private wEe: Float64Array;
  private readonly tE: Float64Array;
  private tick = 0;

  constructor(nReceptors: number, nEffectors: number, params: SornParams, seed: number) {
    this.nNodes = params.N;
    this.nReceptors = nReceptors;
    this.nEffectors = nEffectors;
    this.nInhibitory = Math.round(params.inhibitoryFraction * params.N);
    this.params = { ...params };

    const rng = new Rng(seed);
    const nE = this.nNodes;
    const nI = this.nInhibitory;

    this.eeMask = bernoulliMask(nE, nE, params.pEe, rng, true);
    const eiMask = bernoulliMask(nE, nI, params.pEi, rng);
    const ieMask = bernoulliMask(nI, nE, params.pIe, rng);
    const inputMask = bernoulliMask(nE, nReceptors, params.pInput, rng);
    this.outputMask = bernoulliMask(nE, nEffectors, params.pOutput, rng);

    ensureEachRow(this.eeMask, nE, nE, rng, true);
    ensureEachRow(eiMask, nE, nI, rng);
    ensureEachRow(ieMask, nI, nE, rng);
    ensureEachRow(inputMask, nE, nReceptors, rng);
    ensureEachColumn(this.outputMask, nE, nEffectors, rng);

    this.wEe = rowNormalisedWeights(this.eeMask, nE, nE, params.eeRowSum, rng);
    this.cE = new Float64Array(nE);
    for (let row = 0; row < nE; row++) {
      const offset = row * nE;
      for (let col = 0; col < nE; col++) this.cE[row] += this.wEe[offset + col];
    }
    this.wEi = rowNormalisedWeights(eiMask, nE, nI, params.eiRowSum, rng);
    this.wIe = rowNormalisedWeights(ieMask, nI, nE, params.ieRowSum, rng);
    this.wEu = rowNormalisedWeights(inputMask, nE, nReceptors, params.inputRowSum, rng);

    this.tE = new Float64Array(nE);
    this.tI = new Float64Array(nI);
    for (let index = 0; index < nE; index++) this.tE[index] = params.tEMax * rng.uniform();
    for (let index = 0; index < nI; index++) this.tI[index] = params.tIMax * rng.uniform();

    this.x = new Float64Array(nE);
    this.y = new Float64Array(nI);
    this.prevX = new Float64Array(nE);
    this.prevY = new Float64Array(nI);
  }

  get currentTick(): number {
    return this.tick;
  }

  step(receptors: ArrayLike<number>): Float64Array {
    if (receptors.length !== this.nReceptors) {
      throw new RangeError(`expected ${this.nReceptors} receptor currents, got ${receptors.length}`);
    }

    const nE = this.nNodes;
    const nI = this.nInhibitory;
    this.prevX.set(this.x);
    this.prevY.set(this.y);

    for (let row = 0; row < nE; row++) {
      let excitation = 0;
      const eeOffset = row * nE;
      for (let col = 0; col < nE; col++) excitation += this.wEe[eeOffset + col] * this.prevX[col];

      let inhibition = 0;
      const eiOffset = row * nI;
      for (let col = 0; col < nI; col++) inhibition += this.wEi[eiOffset + col] * this.prevY[col];

      let input = 0;
      const inputOffset = row * this.nReceptors;
      for (let col = 0; col < this.nReceptors; col++) {
        input += this.wEu[inputOffset + col] * receptors[col];
      }
      this.x[row] = excitation - inhibition + input - this.tE[row] >= 0 ? 1 : 0;
    }

    for (let row = 0; row < nI; row++) {
      let excitation = 0;
      const offset = row * nE;
      for (let col = 0; col < nE; col++) excitation += this.wIe[offset + col] * this.prevX[col];
      this.y[row] = excitation - this.tI[row] >= 0 ? 1 : 0;
    }

    if (this.params.learnOn) this.applyPlasticity();
    this.tick += 1;
    return this.x;
  }

  effectorOutputs(): number[] {
    const output = new Array<number>(this.nEffectors).fill(0);
    for (let effector = 0; effector < this.nEffectors; effector++) {
      let count = 0;
      let total = 0;
      for (let node = 0; node < this.nNodes; node++) {
        if (!this.outputMask[node * this.nEffectors + effector]) continue;
        count += 1;
        total += this.x[node];
      }
      output[effector] = count === 0 ? 0 : total / count;
    }
    return output;
  }

  /** Small deterministic fingerprint used by browser-runtime tests. */
  stateFingerprint(): number[] {
    return [
      this.tick,
      this.x.reduce((sum, value) => sum + value, 0),
      this.y.reduce((sum, value) => sum + value, 0),
      this.tE.reduce((sum, value) => sum + value, 0),
      this.wEe.reduce((sum, value) => sum + value, 0),
    ];
  }

  private applyPlasticity(): void {
    const nE = this.nNodes;
    const etaStdp = this.params.etaStdp;

    for (let row = 0; row < nE; row++) {
      const offset = row * nE;
      for (let col = 0; col < nE; col++) {
        const index = offset + col;
        if (!this.eeMask[index]) {
          this.wEe[index] = 0;
          continue;
        }
        const delta = etaStdp * (
          this.x[row] * this.prevX[col] - this.prevX[row] * this.x[col]
        );
        this.wEe[index] = Math.max(0, this.wEe[index] + delta);
      }
    }

    for (let row = 0; row < nE; row++) {
      this.tE[row] += this.params.etaIp * (this.x[row] - this.params.hIp);
    }

    for (let row = 0; row < nE; row++) {
      const target = this.cE[row];
      if (target <= 0) continue;
      const offset = row * nE;
      let total = 0;
      for (let col = 0; col < nE; col++) total += this.wEe[offset + col];
      if (total <= 0) continue;
      const scale = target / total;
      for (let col = 0; col < nE; col++) this.wEe[offset + col] *= scale;
    }
  }
}
