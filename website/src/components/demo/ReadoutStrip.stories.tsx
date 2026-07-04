import type { Meta, StoryObj } from '@storybook/react-vite';
import { ReadoutStrip } from './ReadoutStrip';

const meta: Meta<typeof ReadoutStrip> = {
  title: 'Demo/ReadoutStrip',
  component: ReadoutStrip,
  parameters: { layout: 'fullscreen' },
};
export default meta;

type Story = StoryObj<typeof ReadoutStrip>;

export const Default: Story = {
  args: {
    tick: 4231,
    meanActivation: 0.482,
    meanAbsError: 0.113,
    meanTarget: 1.27,
    spikeCount: 14,
    nNodes: 100,
    effectorOutputs: [0.32, 0.58],
  },
};

export const Quiet: Story = {
  args: {
    tick: 12,
    meanActivation: 0.01,
    meanAbsError: 0.98,
    meanTarget: 1.0,
    spikeCount: 0,
    nNodes: 100,
    effectorOutputs: [0, 0],
  },
};
