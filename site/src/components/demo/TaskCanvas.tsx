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

/** Swaps in the wall / tracking / pong world renderer for whichever task is active. */
export function TaskCanvas({ snapshot }: TaskCanvasProps) {
  const wallRenderer = useMemo(() => new WallRenderer(), []);
  const trackingRenderer = useMemo(() => new TrackingRenderer(), []);
  const pongRenderer = useMemo(() => new PongRenderer(), []);

  return (
    <div className="h-full w-full bg-paper">
      {snapshot.task === 'wall' && <Canvas2D renderer={wallRenderer} snapshot={snapshot.env} />}
      {snapshot.task === 'tracking' && <Canvas2D renderer={trackingRenderer} snapshot={snapshot.env} />}
      {snapshot.task === 'pong' && <Canvas2D renderer={pongRenderer} snapshot={snapshot.env} />}
    </div>
  );
}
