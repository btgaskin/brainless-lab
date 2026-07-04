import type { Meta, StoryObj } from '@storybook/react-vite';
import { UpdateLoopDiagram } from './UpdateLoopDiagram';

const meta: Meta<typeof UpdateLoopDiagram> = {
  title: 'Explainer/UpdateLoopDiagram',
  component: UpdateLoopDiagram,
  parameters: { layout: 'padded' },
  decorators: [
    (Story) => (
      <div style={{ background: '#fbfaf7', padding: '16px' }}>
        <Story />
      </div>
    ),
  ],
};
export default meta;

type Story = StoryObj<typeof UpdateLoopDiagram>;

export const Idle: Story = { args: { activeStep: null } };
export const IntegrateAndLeak: Story = { args: { activeStep: 0 } };
export const SpikeAndReset: Story = { args: { activeStep: 1 } };
export const HomeostaticUpdate: Story = { args: { activeStep: 2 } };
