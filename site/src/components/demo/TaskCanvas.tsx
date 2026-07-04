import { useMemo } from 'react';
import { Canvas2D } from './Canvas2D';
import { WallRenderer } from './renderers/wallRenderer';
import { TrackingRenderer } from './renderers/trackingRenderer';
import { PongRenderer } from './renderers/pongRenderer';
import type { WallSnapshot } from '../../simulation/tasks/wall';
import type { TrackingSnapshot } from '../../simulation/tasks/tracking';
import type { PongSnapshot } from '../../simulation/tasks/pong';

export type TaskWorldSnapshot =
  | { task: 'wall'; env: WallSnapshot }
  | { task: 'tracking'; env: TrackingSnapshot }
  | { task: 'pong'; env: PongSnapshot };

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

  return (
    <div className="h-full w-full overflow-hidden rounded-lg border border-grid bg-card">
      {snapshot.task === 'wall' && <Canvas2D renderer={wallRenderer} snapshot={snapshot.env} />}
      {snapshot.task === 'tracking' && <Canvas2D renderer={trackingRenderer} snapshot={snapshot.env} />}
      {snapshot.task === 'pong' && <Canvas2D renderer={pongRenderer} snapshot={snapshot.env} />}
    </div>
  );
}
