import { CANONICAL_CORE_V2, CORE_TASK_NAMES, canonicalParamsFor, displayRootCandidates } from '../src/simulation/canonical';
import { createCoreSimulation, evaluateCoreDisplayCandidate } from '../src/simulation/coreRuntime';
import { DISPLAY_CASES, type DisplayCaseSelection } from '../src/simulation/displayCases';
import { derivePortSeed } from '../src/simulation/rng';
import type { CoreTaskName } from '../src/simulation/types';

const QUANTILE = 0.7;

export function selectDisplayCase(task: CoreTaskName): DisplayCaseSelection {
  const protocol = CANONICAL_CORE_V2[task];
  const candidates = displayRootCandidates(task).map((rootSeed) => {
    const simulation = createCoreSimulation(task, canonicalParamsFor(task), rootSeed);
    const outcome = evaluateCoreDisplayCandidate(simulation, protocol.horizon, protocol.warmup);
    if (!Number.isFinite(outcome.raw)) throw new Error(`${task} root ${rootSeed} produced a non-finite outcome`);
    return { rootSeed, outcome };
  });
  candidates.sort((left, right) => left.outcome.raw - right.outcome.raw || left.rootSeed - right.rootSeed);
  const rank = Math.ceil(QUANTILE * candidates.length) - 1;
  const selected = candidates[rank];
  return {
    rootSeed: selected.rootSeed,
    outcomeKey: selected.outcome.key,
    rawOutcome: selected.outcome.raw,
    candidateCount: candidates.length,
    quantile: QUANTILE,
    topologySeed: derivePortSeed(selected.rootSeed, 'topology', 1, 1, 1),
    worldSeed: derivePortSeed(selected.rootSeed, 'world', 1, 1),
  };
}

function selectionsMatch(left: DisplayCaseSelection, right: DisplayCaseSelection): boolean {
  return left.rootSeed === right.rootSeed
    && left.outcomeKey === right.outcomeKey
    && left.candidateCount === right.candidateCount
    && left.quantile === right.quantile
    && left.topologySeed === right.topologySeed
    && left.worldSeed === right.worldSeed
    && Math.abs(left.rawOutcome - right.rawOutcome) <= 1e-12;
}

const selections = Object.fromEntries(
  CORE_TASK_NAMES.map((task) => {
    process.stderr.write(`Selecting ${task} display case...\n`);
    return [task, selectDisplayCase(task)];
  }),
) as Record<CoreTaskName, DisplayCaseSelection>;

if (process.argv.includes('--check')) {
  const changed = CORE_TASK_NAMES.filter((task) => !selectionsMatch(selections[task], DISPLAY_CASES[task]));
  if (changed.length > 0) {
    process.stderr.write(`Display-case selections are stale for: ${changed.join(', ')}\n`);
    process.stderr.write(`${JSON.stringify(selections, null, 2)}\n`);
    process.exit(1);
  }
  process.stdout.write('Display-case selections are current.\n');
} else {
  process.stdout.write(`${JSON.stringify(selections, null, 2)}\n`);
}
