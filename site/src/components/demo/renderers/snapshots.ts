/** Scene data used by renderers. No world or neural update equations live here. */
export interface TrackingSnapshot { headingDeg: number; stimulusDeg: number }
export interface PongSnapshot {
  arenaW: number; arenaH: number; ballR: number; paddleX: number; paddleH: number;
  ballX: number; ballY: number; paddleY: number;
}
export interface PlankCartPoleSnapshot {
  level: 'easy'; levelLabel: string; observationLabel: string; actionCount: number;
  encoder: 'argyle_4'; x: number; theta: number; maxX: number;
  stepCount: number; missionSteps: number; noopFraction: number;
  done: boolean; lastAction: 'left' | 'right' | 'noop' | null;
}
