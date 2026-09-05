import { useMemo } from 'react';
import { Canvas2D } from './Canvas2D';
import { TrackingRenderer } from './renderers/trackingRenderer';
import { PongRenderer } from './renderers/pongRenderer';
import { CartPoleRenderer } from './renderers/cartpoleRenderer';
import type { DemoTaskSnapshot } from '../../simulation/tasks/demo';

export type TaskWorldSnapshot = DemoTaskSnapshot;

export interface TaskCanvasProps {
  snapshot: TaskWorldSnapshot;
}

/**
 * One fixed frame, shared by every task. Each renderer already *contains and
 * centers* its own world on the same card background. Switching tasks keeps
 * the frame fixed and changes only the declared world inside it.
 */
export function TaskCanvas({ snapshot }: TaskCanvasProps) {
  const trackingRenderer = useMemo(() => new TrackingRenderer(), []);
  const pongRenderer = useMemo(() => new PongRenderer(), []);
  const cartPoleRenderer = useMemo(() => new CartPoleRenderer(), []);

  return (
    <div className="h-full w-full overflow-hidden rounded-lg border border-grid bg-card">
      {snapshot.task === 'tracking' && <Canvas2D renderer={trackingRenderer} snapshot={snapshot.env} />}
      {snapshot.task === 'pong' && <Canvas2D renderer={pongRenderer} snapshot={snapshot.env} />}
      {snapshot.task === 'cartpole_plank_easy' && (
        <Canvas2D renderer={cartPoleRenderer} snapshot={snapshot.env} />
      )}
    </div>
  );
}
