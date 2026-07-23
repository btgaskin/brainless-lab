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
      components: {
        Head: './src/components/Head.astro',
        PageTitle: './src/components/PageTitle.astro',
      },
      social: {
        github: 'https://github.com/btgaskin/brainless-lab',
      },
      sidebar: [
        {
          label: 'Start',
          items: [
            { label: 'Getting started', slug: 'core/getting-started' },
            { label: 'Core task tour', slug: 'core/task-tour' },
          ],
        },
        {
          label: 'Run research',
          items: [
            { label: 'Operations and records', slug: 'core/operations-records' },
            { label: 'Design a study', slug: 'core/design-study' },
            { label: 'Runs and results', slug: 'core/runs-results' },
            { label: 'Scoring', slug: 'scoring' },
            { label: 'Analysis', slug: 'analysis' },
            { label: 'Evolution', slug: 'evolution' },
            { label: 'Agent-assisted workflow', slug: 'agentic-workflow' },
          ],
        },
        {
          label: 'Understand',
          items: [
            { label: 'Architecture', slug: 'core/architecture' },
            { label: 'Interaction cycles', slug: 'core/interaction-cycle' },
            { label: 'Falandays node', slug: 'core/falandays' },
            { label: 'Reservoirs and node models', slug: 'core/reservoirs' },
            { label: 'Embodiment', slug: 'core/embodiment' },
            { label: 'Worlds, tasks and populations', slug: 'core/worlds-tasks-populations' },
            { label: 'Node mechanisms', slug: 'node-mechanisms' },
            { label: 'Platform limits', slug: 'platform-limits' },
          ],
        },
        {
          label: 'Build and extend',
          items: [
            { label: 'Extend the lab', slug: 'core/extend' },
            { label: 'Interface contracts', slug: 'contracts' },
            { label: 'Reference', slug: 'reference' },
          ],
        },
        {
          label: 'Experimental',
          items: [
            { label: 'Overview', slug: 'experimental' },
            { label: 'Reservoirs', slug: 'experimental/reservoirs' },
            { label: 'Embodiment', slug: 'experimental/embodiment' },
            { label: 'Worlds and tasks', slug: 'experimental/worlds-tasks' },
            { label: 'Collectives', slug: 'experimental/collectives' },
            { label: 'Analyses', slug: 'experimental/analyses' },
            { label: 'Evolution', slug: 'experimental/evolution' },
          ],
        },
      ],
    }),
  ],
});
