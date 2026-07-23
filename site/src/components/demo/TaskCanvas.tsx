import { useMemo } from 'react';
import { Canvas2D } from './Canvas2D';
import { WallRenderer } from './renderers/wallRenderer';
import { TrackingRenderer } from './renderers/trackingRenderer';
import { PongRenderer } from './renderers/pongRenderer';
import { CartPoleRenderer } from './renderers/cartpoleRenderer';
import type { WallSnapshot } from '../../simulation/tasks/wall';
import type { TrackingSnapshot } from '../../simulation/tasks/tracking';
import type { PongSnapshot } from '../../simulation/tasks/pong';
import {
  isPlankCartPoleTask,
  type PlankCartPoleSnapshot,
} from '../../simulation/tasks/cartpolePlank';
import type { PlankCartPoleTaskName } from '../../simulation/types';

export type TaskWorldSnapshot =
  | { task: 'wall'; env: WallSnapshot }
  | { task: 'tracking'; env: TrackingSnapshot }
  | { task: 'pong'; env: PongSnapshot }
  | { task: PlankCartPoleTaskName; env: PlankCartPoleSnapshot };

export interface TaskCanvasProps {
  snapshot: TaskWorldSnapshot;
}

/**
 * One fixed frame, shared by every task. Each renderer already *contains and
 * centers* its own world on the same card background — wall and tracking fit a
 * square via min(w,h), pong fits its 2:1 arena — so switching tasks keeps the
 * frame identical (same size, same background) and simply nests a different
 * world inside it.
 */
export function TaskCanvas({ snapshot }: TaskCanvasProps) {
  const wallRenderer = useMemo(() => new WallRenderer(), []);
  const trackingRenderer = useMemo(() => new TrackingRenderer(), []);
  const pongRenderer = useMemo(() => new PongRenderer(), []);
  const cartPoleRenderer = useMemo(() => new CartPoleRenderer(), []);

  return (
    <div className="h-full w-full overflow-hidden rounded-lg border border-grid bg-card">
      {snapshot.task === 'wall' && <Canvas2D renderer={wallRenderer} snapshot={snapshot.env} />}
      {snapshot.task === 'tracking' && <Canvas2D renderer={trackingRenderer} snapshot={snapshot.env} />}
      {snapshot.task === 'pong' && <Canvas2D renderer={pongRenderer} snapshot={snapshot.env} />}
      {isPlankCartPoleTask(snapshot.task) && (
        <Canvas2D renderer={cartPoleRenderer} snapshot={snapshot.env as PlankCartPoleSnapshot} />
      )}
    </div>
  );
}
