import type { Meta, StoryObj } from '@storybook/react-vite';
import { TaskCanvas } from './TaskCanvas';
import { runWall, runTracking, runPong } from './mockSnapshots';

const meta: Meta<typeof TaskCanvas> = {
  title: 'Demo/TaskCanvas',
  component: TaskCanvas,
  parameters: { layout: 'fullscreen' },
  decorators: [
    (Story) => (
      <div style={{ height: '360px', width: '480px' }}>
        <Story />
      </div>
    ),
  ],
};
export default meta;

type Story = StoryObj<typeof TaskCanvas>;

export const Wall: Story = { args: { snapshot: { task: 'wall', env: runWall(40) } } };
export const Tracking: Story = { args: { snapshot: { task: 'tracking', env: runTracking(120) } } };
export const Pong: Story = { args: { snapshot: { task: 'pong', env: runPong(60) } } };
