import { Rng } from './rng';
import { bernoulliMask, initWeights } from './wiring';
import type { FalandaysParams, ReservoirSnapshot } from './types';

/**
 * TypeScript port of the Falandays et al. homeostatic leaky-integrate-and-fire
 * reservoir. Ported from src/nodes/Falandays.jl + src/nodes/Axes.jl (read
 * directly, not just the paper) — see types.ts's FalandaysParams doc comments
 * for the two places this deviates from the paper's literal text.
 *
 * Update rule, three steps per tick:
 *   1. integrate & leak:  x = x*(1-leak) + inputWeight*receptors + W_rec . prevSpikes
 *   2. spike & reset:     spike = x >= thresholdMult*target; if spiking, x -= thresholdMult*target
 *   3. homeostatic update: error = x - target;
 *                          target = max(targetFloor, target + lrateTarg*error)
 *                          w[i,j] -= (error[j] / spikingNeighborCount[j]) * lrateWmat
 *                            for each i that spiked last tick and is connected to j
 */
export class FalandaysReservoir {
  readonly nNodes: number;
  readonly nReceptors: number;
  readonly nEffectors: number;
  params: FalandaysParams;

  private acts: Float64Array;
  private targets: Float64Array;
  private spikes: Float64Array;
  private prevSpikes: Float64Array;
  private errors: Float64Array;
  private wmat: Float64Array;
  private readonly wmat0: Float64Array;
  private readonly recurrentMask: Uint8Array;
  private readonly inputMask: Uint8Array;
  private readonly outputMask: Uint8Array;
  private tick = 0;

  // Scratch buffers reused across step() calls — avoids allocating 3 fresh
  // N-sized Float64Arrays every tick (measured as significant GC pressure at
  // N>=500: ~1.7ms/tick before this change, most of it allocation, not math).
  private readonly inputCurrentBuf: Float64Array;
  private readonly recurrentCurrentBuf: Float64Array;
  private readonly spikingNeighborCountBuf: Float64Array;

  constructor(nReceptors: number, nEffectors: number, params: FalandaysParams, seed: number) {
    this.nNodes = params.N;
    this.nReceptors = nReceptors;
    this.nEffectors = nEffectors;
    this.params = params;

    const rng = new Rng(seed);
    const n = this.nNodes;

    this.recurrentMask = bernoulliMask(n, n, params.linkP, rng, true);
    this.inputMask = bernoulliMask(nReceptors, n, params.linkP, rng, false);
    this.outputMask = bernoulliMask(n, nEffectors, params.linkP, rng, false);

    this.wmat0 = initWeights(this.recurrentMask, n, params, rng);
    this.wmat = this.wmat0.slice();

    this.acts = new Float64Array(n);
    this.targets = new Float64Array(n).fill(1.0);
    this.spikes = new Float64Array(n);
    this.prevSpikes = new Float64Array(n);
    this.errors = new Float64Array(n);

    this.inputCurrentBuf = new Float64Array(n);
    this.recurrentCurrentBuf = new Float64Array(n);
    this.spikingNeighborCountBuf = new Float64Array(n);
  }

  reset(): void {
    this.wmat.set(this.wmat0);
    this.acts.fill(0);
    this.targets.fill(1.0);
    this.spikes.fill(0);
    this.prevSpikes.fill(0);
    this.errors.fill(0);
    this.tick = 0;
  }

  step(receptors: ArrayLike<number>): Float64Array {
    const n = this.nNodes;
    const p = this.params;
    this.prevSpikes.set(this.spikes);

    const inputCurrent = this.inputCurrentBuf;
    inputCurrent.fill(0);
    for (let i = 0; i < this.nReceptors; i++) {
      const r = receptors[i];
      if (r === 0) continue;
      const rowOff = i * n;
      for (let j = 0; j < n; j++) {
        if (this.inputMask[rowOff + j]) inputCurrent[j] += r * p.inputWeight;
      }
    }

    const recurrentCurrent = this.recurrentCurrentBuf;
    recurrentCurrent.fill(0);
    for (let i = 0; i < n; i++) {
      if (this.prevSpikes[i] === 0) continue;
      const rowOff = i * n;
      for (let j = 0; j < n; j++) recurrentCurrent[j] += this.wmat[rowOff + j];
    }

    for (let i = 0; i < n; i++) {
      let x = this.acts[i] * (1 - p.leak) + inputCurrent[i] + recurrentCurrent[i];
      if (p.rectify && x < 0) x = 0;
      this.acts[i] = x;
    }

    for (let i = 0; i < n; i++) {
      const threshold = this.targets[i] * p.thresholdMult;
      if (this.acts[i] >= threshold) {
        this.spikes[i] = 1;
        this.acts[i] -= threshold;
      } else {
        this.spikes[i] = 0;
      }
      this.errors[i] = this.acts[i] - this.targets[i];
    }

    if (p.learnWeights) {
      const spikingNeighborCount = this.spikingNeighborCountBuf;
      spikingNeighborCount.fill(0);
      for (let i = 0; i < n; i++) {
        if (this.prevSpikes[i] === 0) continue;
        const rowOff = i * n;
        for (let j = 0; j < n; j++) {
          if (this.recurrentMask[rowOff + j]) spikingNeighborCount[j] += 1;
        }
      }
      for (let j = 0; j < n; j++) {
        const count = spikingNeighborCount[j];
        if (count === 0) continue;
        const delta = (this.errors[j] / count) * p.lrateWmat;
        for (let i = 0; i < n; i++) {
          if (this.prevSpikes[i] !== 0 && this.recurrentMask[i * n + j]) {
            this.wmat[i * n + j] -= delta;
          }
        }
      }
    }

    if (p.learnTargets) {
      for (let i = 0; i < n; i++) {
        let t = this.targets[i] + this.errors[i] * p.lrateTarg;
        if (t < p.targetFloor) t = p.targetFloor;
        this.targets[i] = t;
      }
    }

    this.tick += 1;
    return this.spikes;
  }

  effectorOutputs(): number[] {
    const out = new Array<number>(this.nEffectors).fill(0);
    for (let k = 0; k < this.nEffectors; k++) {
      let count = 0;
      let total = 0;
      for (let i = 0; i < this.nNodes; i++) {
        if (this.outputMask[i * this.nEffectors + k]) {
          count += 1;
          total += this.spikes[i];
        }
      }
      out[k] = count > 0 ? total / count : 0;
    }
    return out;
  }

  snapshot(): ReservoirSnapshot {
    return {
      nNodes: this.nNodes,
      nReceptors: this.nReceptors,
      nEffectors: this.nEffectors,
      tick: this.tick,
      acts: this.acts.slice(),
      targets: this.targets.slice(),
      spikes: this.spikes.slice(),
      errors: this.errors.slice(),
      wmat: this.wmat.slice(),
      recurrentMask: this.recurrentMask,
      outputMask: this.outputMask,
      effectorOutputs: this.effectorOutputs(),
    };
  }
}
