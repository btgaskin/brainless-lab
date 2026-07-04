import type { Meta, StoryObj } from '@storybook/react-vite';
import { SimDemo } from './SimDemo';

const meta: Meta<typeof SimDemo> = {
  title: 'Demo/SimDemo',
  component: SimDemo,
  parameters: { layout: 'fullscreen' },
};
export default meta;

type Story = StoryObj<typeof SimDemo>;

export const Default: Story = {};
