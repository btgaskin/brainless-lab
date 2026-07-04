// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import react from '@astrojs/react';
import remarkMath from 'remark-math';
import rehypeKatex from 'rehype-katex';

// BrainlessLab docs + outputs site.
// Math: remark-math (source) -> rehype-katex (render); KaTeX CSS is pulled in via
// customCss below. The interactive Falandays demo mounts as a React island.
export default defineConfig({
  site: 'https://brainlesslab.dev', // TODO: set the real deploy URL
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
      customCss: ['katex/dist/katex.min.css', './src/styles/theme.css'],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/OWNER/brainless-lab' },
      ],
      sidebar: [
        { label: 'Introduction', slug: 'introduction' },
        { label: 'Concepts', slug: 'concepts' },
        {
          label: 'Nodes',
          items: [
            { label: 'Overview', slug: 'nodes/overview' },
            { label: 'Falandays: base vs extended', slug: 'nodes/falandays' },
          ],
        },
        { label: 'Environments & Tasks', slug: 'environments-tasks' },
        { label: 'Analysis', slug: 'analysis' },
        { label: 'Tooling', slug: 'tooling' },
        { label: 'Extending it', slug: 'extending' },
        { label: 'Reference', slug: 'reference' },
        {
          label: 'Outputs',
          items: [{ label: 'Overview', slug: 'outputs/overview' }],
        },
      ],
    }),
  ],
});
