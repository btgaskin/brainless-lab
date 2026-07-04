import { SimDemo } from './demo/SimDemo';

/**
 * The landing-page demo island: the real in-browser Falandays simulation
 * (SimDemo), full-width within the landing page's single editorial column
 * (the splash --sl-content-width set in theme.css). `not-content` keeps
 * Starlight's markdown styling from bleeding into the island.
 */
export default function FalandaysDemo() {
  return (
    <div className="not-content mx-auto w-full">
      <SimDemo />
    </div>
  );
}
