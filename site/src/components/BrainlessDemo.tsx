import { SimDemo } from './demo/SimDemo';

/**
 * Landing-page player for recorded Quadrants development cases.
 * `not-content` keeps Starlight's Markdown styles outside the interactive UI.
 */
export default function BrainlessDemo() {
  return (
    <div className="not-content mx-auto w-full">
      <SimDemo />
    </div>
  );
}
