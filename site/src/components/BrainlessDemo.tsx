import { SimDemo } from './demo/SimDemo';

/**
 * Landing-page demo island for comparing neuron designs in the same tasks.
 * `not-content` keeps Starlight's Markdown styles outside the interactive UI.
 */
export default function BrainlessDemo() {
  return (
    <div className="not-content mx-auto w-full">
      <SimDemo />
    </div>
  );
}
