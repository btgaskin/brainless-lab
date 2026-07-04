import { DEFAULT_PARAMS, type FalandaysParams, type TaskName } from './types';

/**
 * Confirmed against the actual numpy reference (neural-cognition/v0 and
 * v0.2's crho/falandays.py), which BrainlessLab.jl was built to be
 * bit-exact with: `wmat -= d * lrate_wmat` with `lrate_wmat: float = 0.1`
 * as its own default. (An earlier version of this file offered a "Paper vs.
 * Repo" toggle that also swapped lrateWmat between 1.0/0.1, on the wrong
 * assumption that the paper's literal rule was undamped — the paper's
 * equation 5 lost its numeric coefficient in a copy/paste, same as the
 * connection-probability symbols, and the gap was filled with an assumption
 * instead of being left unknown. That toggle is gone; this is the one set
 * of base params, editable directly via the sliders.)
 */
export const BASE_PARAMS: FalandaysParams = { ...DEFAULT_PARAMS };

export interface TaskTuning {
  /** Falandays et al.'s per-task input gain — the paper's own tuning. */
  inputWeight: number;
  /** Falandays et al.'s per-task reservoir size N — the paper's own tuning. */
  N: number;
  /** Authors' per-task recurrent homeostasis rate. */
  lrateWmat: number;
  /** Authors' per-task target homeostasis rate. */
  lrateTarg: number;
  /** Authors' per-task recurrent initialization scheme. */
  weightInitMode: FalandaysParams['weightInitMode'];
}

/**
 * Per-task tuning, mirrored from src/api/paper_config.jl, which is backed by
 * the authors' original Julia task scripts — NOT the numpy reference's defaults:
 *
 *   "used the homeostatic network (N=200) to control an agent that can
 *    rotate left or right" (tracking)
 *   "our reservoir network (N=500) would show similar performance" (pong)
 *   "our homeostatic network (N=200) would produce movement patterns" (wall)
 *
 * plus "Plink=.1" for input/recurrent/output connectivity in every case
 * study, confirming the linkP=0.1 default. The numpy reference
 * (neural-cognition/v0(.2)) instead uses one uniform default_N=1000 across
 * every task — that's a deliberate choice for *its own* large-scale
 * statistical benchmarking (500 seeds per condition), not a reproduction of
 * the paper's per-task N. Since this demo is framed around the published
 * paper, the paper's numbers are what drive it here.
 *
 * Applied as the starting value when switching tasks; both inputWeight and N
 * remain freely editable from there via the sliders. Effector gains
 * (10 deg/tick tracking, 100 px/tick pong) are architectural, not tunable —
 * they live in each task module, not here.
 */
export const TASK_TUNING: Record<TaskName, TaskTuning> = {
  wall: { inputWeight: 4.0, N: 200, lrateWmat: 1.0, lrateTarg: 0.01, weightInitMode: 'excitatory' },
  tracking: { inputWeight: 0.75, N: 200, lrateWmat: 1.0, lrateTarg: 0.01, weightInitMode: 'excitatory' },
  pong: { inputWeight: 2.75, N: 500, lrateWmat: 1.0, lrateTarg: 0.1, weightInitMode: 'pongMixed' },
};

export function taskTuningFor(task: TaskName): TaskTuning {
  return TASK_TUNING[task];
}
