import { useState } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { ControlPanel } from './ControlPanel';
import { DEFAULT_PARAMS, type FalandaysParams, type TaskName } from '../../simulation/types';

const meta: Meta<typeof ControlPanel> = {
  title: 'Demo/ControlPanel',
  component: ControlPanel,
  parameters: { layout: 'centered' },
  decorators: [
    (Story) => (
      <div style={{ width: '320px', height: '640px', background: '#fbfaf7', padding: '16px' }}>
        <Story />
      </div>
    ),
  ],
};
export default meta;

type Story = StoryObj<typeof ControlPanel>;

function InteractiveControlPanel() {
  const [params, setParams] = useState<FalandaysParams>(DEFAULT_PARAMS);
  const [task, setTask] = useState<TaskName>('wall');
  const [running, setRunning] = useState(false);

  return (
    <ControlPanel
      className="h-full"
      params={params}
      onParamsChange={setParams}
      task={task}
      onTaskChange={setTask}
      running={running}
      onTogglePlay={() => setRunning((r) => !r)}
      onStep={() => {}}
      onReset={() => setParams(DEFAULT_PARAMS)}
    />
  );
}

export const Default: Story = { render: () => <InteractiveControlPanel /> };
