import type { Meta, StoryObj } from '@storybook/react-vite';
import { ReservoirArchitectureDiagram } from './ReservoirArchitectureDiagram';

const meta: Meta<typeof ReservoirArchitectureDiagram> = {
  title: 'Explainer/ReservoirArchitectureDiagram',
  component: ReservoirArchitectureDiagram,
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

type Story = StoryObj<typeof ReservoirArchitectureDiagram>;

export const Default: Story = {};
