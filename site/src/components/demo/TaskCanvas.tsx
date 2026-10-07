import { useMemo } from 'react';
import { Canvas2D } from './Canvas2D';
import { TrackingRenderer } from './renderers/trackingRenderer';
import { PongRenderer } from './renderers/pongRenderer';
import { CartPoleRenderer } from './renderers/cartpoleRenderer';
import { scalar, type ReplayFrame } from './replay';

export function TaskCanvas({ task, frame }: { task: string; frame: ReplayFrame }) {
  const tracking = useMemo(() => new TrackingRenderer(), []);
  const pong = useMemo(() => new PongRenderer(), []);
  const cartpole = useMemo(() => new CartPoleRenderer(), []);
  const world = frame.world;
  const radiansToDegrees = (value: number | undefined) => value === undefined ? undefined : value * 180 / Math.PI;
  const heading = scalar(world, 'headingDeg', 'heading_deg') ?? radiansToDegrees(scalar(world, 'theta'));
  const stimulus = scalar(world, 'stimulusDeg', 'stimulus_deg') ?? radiansToDegrees(scalar(world, 'phi'));
  const ballX = scalar(world, 'ballX', 'ball_x');
  const ballY = scalar(world, 'ballY', 'ball_y');
  const paddleY = scalar(world, 'paddleY', 'paddle_y');
  const x = scalar(world, 'x');
  const theta = scalar(world, 'theta');
  return <div className="h-full w-full overflow-hidden rounded-lg border border-grid bg-card">
    {task === 'tracking' && heading !== undefined && stimulus !== undefined ?
      <Canvas2D renderer={tracking} snapshot={{ headingDeg: heading, stimulusDeg: stimulus }} /> :
    task === 'pong' && ballX !== undefined && ballY !== undefined && paddleY !== undefined ?
      <Canvas2D renderer={pong} snapshot={{ ballX, ballY, paddleY,
        arenaW: scalar(world, 'arenaW', 'arena_w', 'width') ?? 1000, arenaH: scalar(world, 'arenaH', 'arena_h', 'height') ?? 500,
        ballR: scalar(world, 'ballR', 'ball_r') ?? 15, paddleX: scalar(world, 'paddleX', 'paddle_x') ?? 100,
        paddleH: scalar(world, 'paddleH', 'paddle_h') ?? 100 }} /> :
    task === 'cartpole_plank_easy' && x !== undefined && theta !== undefined ?
      <Canvas2D renderer={cartpole} snapshot={{ level: 'easy', levelLabel: 'Easy', observationLabel: '4-state',
        actionCount: 2, encoder: 'argyle_4', x, theta, maxX: scalar(world, 'maxX', 'max_x') ?? 2.4,
        stepCount: frame.tick, missionSteps: scalar(world, 'missionSteps', 'mission_steps') ?? 15000,
        noopFraction: 0, done: world.done === true || world.done === 1, lastAction: null }} /> :
      <div className="flex h-full flex-col justify-center gap-4 px-5 py-4">
        <p className="text-sm text-ink-soft">Recorded emitted activity</p>
        <div className="flex max-h-32 flex-wrap gap-1 overflow-hidden" aria-label={`${frame.activity.length} recorded neural activities`}>
          {frame.activity.map((value, index) => <span key={index} className={`h-2 w-2 rounded-sm ${value > 0 ? 'bg-teal' : 'bg-grid'}`} />)}
        </div>
        <p className="font-mono text-xs text-ink-soft">Inputs {frame.inputs.map((value) => value.toFixed(2)).join(', ')}</p>
      </div>}
  </div>;
}
