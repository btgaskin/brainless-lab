export interface FalandaysParams {
  /**
   * Reservoir size. Task-specific in the actual published paper (Falandays
   * et al. 2023): N=200 for tracking and wall, N=500 for pong — see
   * presets.ts's TASK_TUNING, applied on task switch. (An earlier version of
   * this file used the numpy reference's uniform default_N=1000 instead —
   * that's the reference codebase's own choice for its large-scale
   * statistical benchmarking, not the paper's per-task values; wrong
   * reference point for a demo framed around the published paper.) This
   * default is just the fallback before a task is selected. The demo does
   * not render individual nodes or edges, but its O(N^2) reservoir update
   * still makes very large interactive values progressively slower.
   */
  N: number;
  /** Fraction of activation retained is (1-leak) each tick. Paper/repo default 0.25. */
  leak: number;
  /**
   * Recurrent-weight learning rate. The canonical Wall, Tracking, and Pong
   * compositions use 1.0, as recorded in src/api/paper_config.jl.
   */
  lrateWmat: number;
  /** Target homeostasis learning rate. Paper/repo default 0.01. */
  lrateTarg: number;
  /** Spiking threshold = thresholdMult * target. Paper/repo default 2.0. */
  thresholdMult: number;
  /** Lower bound a node's target can homeostatically settle to. Paper/repo default 1.0. */
  targetFloor: number;
  /** Scales receptor current into the reservoir. Per-task in the paper; repo uses one shared value. */
  inputWeight: number;
  /** Recurrent initialization used by the common Falandays task defaults. */
  weightInitMode: 'excitatory' | 'pongMixed' | 'legacyNormal';
  /** Std of the legacy N(0,std) recurrent weight initialization. */
  weightInitStd: number;
  /** Bernoulli connectivity probability for recurrent/input/output wiring. Repo default 0.1. */
  linkP: number;
  /** Clip negative activations to 0 before the spike check. Authors' common-task default is false. */
  rectify: boolean;
  /**
   * Independent toggles beyond what the repo exposes (repo has one combined
   * `learn_on` flag) — split here so the demo can isolate weight-plasticity
   * from target-homeostasis, since the paper discusses them as separable ideas.
   */
  learnWeights: boolean;
  learnTargets: boolean;
}

export const DEFAULT_PARAMS: FalandaysParams = {
  N: 200,
  leak: 0.25,
  lrateWmat: 1.0,
  lrateTarg: 0.01,
  thresholdMult: 2.0,
  targetFloor: 1.0,
  inputWeight: 1.875,
  weightInitMode: 'excitatory',
  weightInitStd: 1.0,
  linkP: 0.1,
  rectify: false,
  learnWeights: true,
  learnTargets: true,
};

export type PlankCartPoleTaskName =
  | 'cartpole_plank_easy'
  | 'cartpole_plank_medium'
  | 'cartpole_plank_hard'
  | 'cartpole_plank_hardest';

export type CoreTaskName = 'wall' | 'tracking' | 'pong';

export type TaskName = CoreTaskName | PlankCartPoleTaskName;

export interface TaskEnv<Snapshot = unknown> {
  readonly nReceptors: number;
  readonly nEffectors: number;
  /**
   * Native reservoir updates per world step. Most browser tasks use one.
   * Temporal tasks can expose frame-specific receptor vectors and reduce the
   * resulting effector frames without coupling the simulation loop to a task
   * name.
   */
  readonly neuralFrames?: number;
  sense(): Float64Array;
  senseFrame?(frame: number): Float64Array;
  reduceEffectors?(frames: readonly number[][]): number[];
  isTerminal?(): boolean;
  step(effectors: number[]): void;
  reset(): void;
  snapshot(): Snapshot;
}
