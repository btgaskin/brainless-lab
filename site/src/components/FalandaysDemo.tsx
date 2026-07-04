import { SimDemo } from './demo/SimDemo';

/**
 * The landing-page demo island: the real in-browser Falandays simulation
 * (SimDemo — task canvases + control panel + readout, wired to the TS
 * FalandaysReservoir port under ./demo and ../simulation). Mounted with
 * client:load from the MDX landing.
 */
export default function FalandaysDemo() {
  return <SimDemo />;
}
