// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import react from '@astrojs/react';
import remarkMath from 'remark-math';
import rehypeKatex from 'rehype-katex';
import tailwindcss from '@tailwindcss/vite';

// BrainlessLab docs + outputs site.
// Math: remark-math (source) -> rehype-katex (render); KaTeX CSS is pulled in via
// customCss below. The recorded Quadrants player mounts as a React island.
export default defineConfig({
  site: 'https://brainless-lab.pages.dev',
  redirects: {
    '/core/getting-started': '/tutorials/first-simulation/',
    '/core/task-tour': '/reference/core-catalog/',
    '/core/architecture': '/handbook/system-map/',
    '/core/design-study': '/handbook/experiments-evidence/',
    '/core/embodiment': '/handbook/bodies-interaction/',
    '/core/interaction-cycle': '/handbook/bodies-interaction/',
    '/core/extend': '/handbook/extending/',
    '/core/falandays': '/handbook/nodes-reservoirs/',
    '/core/reservoirs': '/handbook/nodes-reservoirs/',
    '/core/operations-records': '/handbook/operations/',
    '/core/runs-results': '/handbook/records-results/',
    '/core/worlds-tasks-populations': '/handbook/worlds-tasks-populations/',
    '/node-mechanisms': '/handbook/nodes-reservoirs/',
    '/analysis': '/reference/analysis/',
    '/contracts': '/reference/interfaces/',
    '/evolution': '/handbook/operations/',
    '/scoring': '/reference/core-catalog/',
    '/agentic-workflow': '/tutorials/extend-project/',
    '/tutorials/evolve-ctrnn': '/experimental/features/development-evolution/',
    '/tutorials/resume-evolution': '/experimental/features/development-evolution/',
    '/tutorials/benchmark-evolved-ctrnn': '/experimental/features/development-evolution/',
    '/benchmarks/falandays-core-v2': '/benchmarks/',
    '/experimental/reservoirs': '/experimental/',
    '/experimental/embodiment': '/experimental/',
    '/experimental/worlds-tasks': '/experimental/',
    '/experimental/collectives': '/experimental/',
    '/experimental/analyses': '/experimental/',
    '/experimental/evolution': '/experimental/',
  },
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
        'Study how local neural adaptation affects task behaviour with Python and Quadrants.',
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
        Header: './src/components/Header.astro',
        Hero: './src/components/LandingHero.astro',
        PageTitle: './src/components/PageTitle.astro',
      },
      social: {
        github: 'https://github.com/btgaskin/brainless-lab',
      },
      sidebar: [
        {
          label: 'Get started',
          items: [
            { label: 'Start here', slug: 'start' },
            { label: 'Run your first simulation', slug: 'tutorials/first-simulation' },
          ],
        },
        {
          label: 'Tasks and models',
          collapsed: true,
          items: [
            { label: 'Choose a task', slug: 'benchmarks/tasks' },
            {
              label: 'Physical control',
              collapsed: true,
              items: [
                { label: 'Tracking', slug: 'benchmarks/tasks/tracking' },
                { label: 'Pong', slug: 'benchmarks/tasks/pong' },
                { label: 'CartPole', slug: 'benchmarks/tasks/cartpole-plank-easy' },
              ],
            },
            {
              label: 'Capacity probes',
              collapsed: true,
              items: [
                { label: 'Overview and preset cells', slug: 'benchmarks/probes' },
                { label: 'Delayed cue', slug: 'benchmarks/tasks/delayed-cue' },
                { label: 'Recall interference', slug: 'benchmarks/probes/recall' },
                { label: 'Delayed XOR', slug: 'benchmarks/probes/xor' },
                { label: 'Evidence accumulation', slug: 'benchmarks/probes/evidence' },
                { label: 'Context integration', slug: 'benchmarks/probes/context' },
                { label: 'Temporal order', slug: 'benchmarks/probes/order' },
                { label: 'Reversal adaptation', slug: 'benchmarks/probes/reversal' },
              ],
            },
            {
              label: 'Neural models',
              collapsed: true,
              items: [
                { label: 'Overview', slug: 'benchmarks/models' },
                { label: 'Falandays', slug: 'benchmarks/models/falandays' },
                { label: 'SORN', slug: 'benchmarks/models/sorn' },
              ],
            },
          ],
        },
        {
          label: 'Run studies',
          collapsed: true,
          items: [
            { label: 'Create a reproducible profile', slug: 'tutorials/reproducible-profile' },
            { label: 'Compare conditions', slug: 'tutorials/compare-conditions' },
            { label: 'Choose an operation', slug: 'handbook/operations' },
            { label: 'Compare across four tasks', slug: 'benchmarks' },
            { label: 'Decode recorded activity', slug: 'benchmarks/probes/decoding' },
          ],
        },
        {
          label: 'Understand the system',
          collapsed: true,
          items: [
            { label: 'System map', slug: 'handbook/system-map' },
            { label: 'Nodes and reservoirs', slug: 'handbook/nodes-reservoirs' },
            { label: 'Task ports and simulation timing', slug: 'handbook/bodies-interaction' },
            { label: 'Trials, blocks and random streams', slug: 'handbook/evaluation' },
          ],
        },
        {
          label: 'Reference',
          collapsed: true,
          items: [
            { label: 'Python API and CLI', slug: 'reference' },
            { label: 'Plan format', slug: 'reference/plan-format' },
            { label: 'Task contracts', slug: 'reference/core-catalog' },
            { label: 'Outcomes, calibration and uncertainty', slug: 'reference/analysis' },
            { label: 'Record format and inspection', slug: 'handbook/records-results' },
            { label: 'Glossary', slug: 'glossary' },
          ],
        },
        {
          label: 'Develop BrainlessLab',
          collapsed: true,
          items: [
            { label: 'Extend a model, task or analysis', slug: 'handbook/extending' },
            { label: 'Learn the implementation', slug: 'python/learning' },
            { label: 'Measure speed and memory', slug: 'python/performance' },
            { label: 'Implementation interfaces', slug: 'reference/interfaces' },
          ],
        },
        {
          label: 'Evidence and scope',
          collapsed: true,
          items: [
            { label: 'Supported scope and qualification', slug: 'platform-limits' },
            { label: 'Research stages and evidence', slug: 'handbook/experiments-evidence' },
            { label: 'Accepted runs', slug: 'research/catalogue' },
          ],
        },
        {
          label: 'History',
          collapsed: true,
          items: [
            { label: 'Version history', slug: 'legacy' },
            {
              label: 'Historical experiments',
              collapsed: true,
              items: [
                { label: 'Overview', slug: 'experiments' },
                { label: 'Tracking plasticity and branching', slug: 'experiments/tracking-plasticity-branching' },
              ],
            },
            { label: 'Planned capacity study', slug: 'benchmarks/probes/study' },
            { label: 'Historical contribution process', slug: 'research' },
            { label: 'Archived capabilities', slug: 'experimental' },
          ],
        },
      ],
    }),
  ],
});
