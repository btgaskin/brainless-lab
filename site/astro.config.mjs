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
        Hero: './src/components/LandingHero.astro',
        PageTitle: './src/components/PageTitle.astro',
      },
      social: {
        github: 'https://github.com/btgaskin/brainless-lab',
      },
      sidebar: [
        {
          label: 'Tutorials',
          items: [
            { label: 'Run your first simulation', slug: 'tutorials/first-simulation' },
            { label: 'Create a reproducible profile', slug: 'tutorials/reproducible-profile' },
            { label: 'Compare conditions', slug: 'tutorials/compare-conditions' },
            { label: 'Evolve a CTRNN', slug: 'tutorials/evolve-ctrnn' },
            { label: 'Resume evolution', slug: 'tutorials/resume-evolution' },
            { label: 'Benchmark an evolved CTRNN', slug: 'tutorials/benchmark-evolved-ctrnn' },
            { label: 'Extend from another project', slug: 'tutorials/extend-project' },
          ],
        },
        {
          label: 'Handbook',
          items: [
            { label: 'System map', slug: 'handbook/system-map' },
            { label: 'Nodes and reservoirs', slug: 'handbook/nodes-reservoirs' },
            { label: 'Bodies and interaction', slug: 'handbook/bodies-interaction' },
            { label: 'Worlds, tasks and populations', slug: 'handbook/worlds-tasks-populations' },
            { label: 'Evaluation', slug: 'handbook/evaluation' },
            { label: 'Operations', slug: 'handbook/operations' },
            { label: 'Records and results', slug: 'handbook/records-results' },
            { label: 'Experiments and evidence', slug: 'handbook/experiments-evidence' },
            { label: 'Extending BrainlessLab', slug: 'handbook/extending' },
            { label: 'Platform limits', slug: 'platform-limits' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'API, plans, and CLI', slug: 'reference' },
            { label: 'Plan file format', slug: 'reference/plan-format' },
            { label: 'Core catalogue', slug: 'reference/core-catalog' },
            { label: 'Analysis', slug: 'reference/analysis' },
            { label: 'Interfaces', slug: 'reference/interfaces' },
            { label: 'Glossary', slug: 'glossary' },
          ],
        },
        {
          label: 'Research',
          items: [
            { label: 'Record structure', slug: 'research' },
            { label: 'Accepted runs', slug: 'research/catalogue' },
            { label: 'Benchmarks', slug: 'benchmarks' },
            { label: 'Experiments', slug: 'experiments' },
            { label: 'Experimental capabilities', slug: 'experimental' },
          ],
        },
      ],
    }),
  ],
});
