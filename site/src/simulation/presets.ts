import { DEFAULT_PARAMS, type FalandaysParams, type TaskName } from './types';
import { CANONICAL_CORE_V2 } from './canonical';

/** Shared fallback before a registered task preset is applied. */
export const BASE_PARAMS: FalandaysParams = { ...DEFAULT_PARAMS };

export interface TaskTuning {
  /** Falandays et al.'s per-task input gain — the paper's own tuning. */
  inputWeight: number;
  /** Falandays et al.'s per-task reservoir size N — the paper's own tuning. */
  N: number;
  /** Demo starting recurrent homeostasis rate. */
  lrateWmat: number;
  /** Authors' per-task target homeostasis rate. */
  lrateTarg: number;
  /** Authors' per-task recurrent initialization scheme. */
  weightInitMode: FalandaysParams['weightInitMode'];
}

const PLANK_CARTPOLE_TUNING: TaskTuning = {
  inputWeight: 1.875,
  N: 100,
  lrateWmat: 0.1,
  lrateTarg: 0.01,
  weightInitMode: 'excitatory',
};

function coreTuning(task: 'wall' | 'tracking' | 'pong'): TaskTuning {
  const params = CANONICAL_CORE_V2[task].params;
  return {
    inputWeight: params.inputWeight,
    N: params.N,
    lrateWmat: params.lrateWmat,
    lrateTarg: params.lrateTarg,
    weightInitMode: params.weightInitMode,
  };
}

/**
 * Per-task tuning, mostly mirrored from src/api/paper_config.jl, which is backed by
 * the authors' original Julia task scripts — NOT the numpy reference's defaults:
 *
 *   "used the homeostatic network (N=200) to control an agent that can
 *    rotate left or right" (tracking)
 *   "our reservoir network (N=500) would show similar performance" (pong)
 *   "our homeostatic network (N=200) would produce movement patterns" (wall)
 *
 * plus "Plink=.1" for input/recurrent/output connectivity in every case
 * study. The core values match the registered falandays_* compositions used
 * by the version 2 benchmark plan.
 *
 * Applied as the starting value when switching tasks; both inputWeight and N
 * remain freely editable from there via the sliders. Effector gains
 * (10 deg/tick tracking, 100 px/tick pong) are architectural, not tunable —
 * they live in each task module, not here.
 */
export const TASK_TUNING: Record<TaskName, TaskTuning> = {
  wall: coreTuning('wall'),
  tracking: coreTuning('tracking'),
  pong: coreTuning('pong'),
  cartpole_plank_easy: PLANK_CARTPOLE_TUNING,
  cartpole_plank_medium: PLANK_CARTPOLE_TUNING,
  cartpole_plank_hard: PLANK_CARTPOLE_TUNING,
  cartpole_plank_hardest: PLANK_CARTPOLE_TUNING,
};

export function taskTuningFor(task: TaskName): TaskTuning {
  return TASK_TUNING[task];
}
