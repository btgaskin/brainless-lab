/**
 * Seeded PRNG (mulberry32) + Box-Muller gaussian. Deterministic given a seed —
 * needed so "same seed, learning on vs off" comparisons in the demo (and the
 * unit tests) are meaningful.
 */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const MASK_64 = (1n << 64n) - 1n;
const FNV64_OFFSET = 0xcbf29ce484222325n;
const FNV64_PRIME = 0x00000100000001b3n;
const SPLITMIX64_GAMMA = 0x9e3779b97f4a7c15n;
const SPLITMIX64_MIX1 = 0xbf58476d1ce4e5b9n;
const SPLITMIX64_MIX2 = 0x94d049bb133111ebn;

function uint64(value: bigint): bigint {
  return value & MASK_64;
}

function stableStreamWord(name: string): bigint {
  let value = FNV64_OFFSET;
  for (const byte of new TextEncoder().encode(name)) {
    value = uint64((value ^ BigInt(byte)) * FNV64_PRIME);
  }
  return value;
}

function splitmix64(value: bigint): bigint {
  let mixed = uint64(value + SPLITMIX64_GAMMA);
  mixed = uint64((mixed ^ (mixed >> 30n)) * SPLITMIX64_MIX1);
  mixed = uint64((mixed ^ (mixed >> 27n)) * SPLITMIX64_MIX2);
  return uint64(mixed ^ (mixed >> 31n));
}

/** Match EvaluationSpec's stable stream derivation, then fold to the port's 32-bit PRNG. */
export function derivePortSeed(rootSeed: number, stream: 'topology' | 'world', ...coordinates: number[]): number {
  let seed = splitmix64(BigInt(rootSeed) ^ stableStreamWord(stream));
  coordinates.forEach((coordinate, index) => {
    const positionWord = uint64(BigInt(index + 1) * SPLITMIX64_GAMMA);
    seed = splitmix64(seed ^ BigInt(coordinate) ^ positionWord);
  });
  return Number(seed & 0xffffffffn);
}

export class Rng {
  private readonly next: () => number;
  private spare: number | null = null;

  constructor(seed: number) {
    this.next = mulberry32(seed);
  }

  uniform(): number {
    return this.next();
  }

  /** Uniform integer in [0, maxExclusive). */
  int(maxExclusive: number): number {
    return Math.floor(this.next() * maxExclusive);
  }

  /** Standard normal via Box-Muller, one cached "spare" draw per pair. */
  gaussian(): number {
    if (this.spare !== null) {
      const s = this.spare;
      this.spare = null;
      return s;
    }
    let u = 0;
    let v = 0;
    while (u === 0) u = this.next();
    while (v === 0) v = this.next();
    const mag = Math.sqrt(-2 * Math.log(u));
    this.spare = mag * Math.sin(2 * Math.PI * v);
    return mag * Math.cos(2 * Math.PI * v);
  }
}
