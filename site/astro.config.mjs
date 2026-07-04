// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import react from '@astrojs/react';
import remarkMath from 'remark-math';
import rehypeKatex from 'rehype-katex';
import tailwindcss from '@tailwindcss/vite';

// BrainlessLab docs + outputs site.
// Math: remark-math (source) -> rehype-katex (render); KaTeX CSS is pulled in via
// customCss below. The interactive Falandays demo mounts as a React island.
export default defineConfig({
  site: 'https://brainless-lab.pages.dev',
  vite: { plugins: [tailwindcss()] },
  markdown: {
    remarkPlugins: [remarkMath],
    rehypePlugins: [rehypeKatex],
  },
  integrations: [
    react(),
    starlight({
      title: 'BrainlessLab',
      description:
        'Behaviour from collectives of simple neuron-like nodes — brainless cognition. A Diverse Intelligences Summer Institute 2026 project.',
      logo: {
        light: './src/assets/brainless-lab-icon.png',      // dark ink — for light theme
        dark: './src/assets/brainless-lab-icon-dark.png',   // light ink — for dark theme
        alt: 'BrainlessLab',
      },
      favicon: '/favicon-light.png',
      head: [
        // Dark-mode favicon override (light ink); the base favicon above serves light mode,
        // and /favicon.ico in public/ is the universal fallback.
        {
          tag: 'link',
          attrs: {
            rel: 'icon',
            href: '/favicon-dark.png',
            type: 'image/png',
            media: '(prefers-color-scheme: dark)',
          },
        },
      ],
      customCss: ['./src/styles/tailwind.css', 'katex/dist/katex.min.css', './src/styles/theme.css'],
      social: {
        github: 'https://github.com/btgaskin/brainless-lab',
      },
      sidebar: [
        { label: 'Introduction', slug: 'introduction' },
        { label: 'Concepts', slug: 'concepts' },
        {
          label: 'Nodes',
          items: [
            { label: 'Overview', slug: 'nodes/overview' },
            { label: 'Falandays', slug: 'nodes/falandays' },
            { label: 'Neurons', slug: 'nodes/neurons' },
          ],
        },
        { label: 'Environments & Tasks', slug: 'environments-tasks' },
        { label: 'The collective', slug: 'collective' },
        { label: 'Receptors & Effectors', slug: 'receptors-effectors' },
        { label: 'Analysis', slug: 'analysis' },
        { label: 'Evolution', slug: 'evolution' },
        { label: 'Tooling', slug: 'tooling' },
        { label: 'Extending it', slug: 'extending' },
        { label: 'Contracts', slug: 'contracts' },
        {
          label: 'Notes',
          items: [
            { label: 'Criticality & Information', slug: 'notes/criticality-and-information' },
          ],
        },
        { label: 'Reference', slug: 'reference' },
        {
          label: 'Outputs',
          items: [{ label: 'Overview', slug: 'outputs/overview' }],
        },
      ],
    }),
  ],
});
