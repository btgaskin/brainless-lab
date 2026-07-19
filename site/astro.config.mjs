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
      components: { Head: './src/components/Head.astro' },
      social: {
        github: 'https://github.com/btgaskin/brainless-lab',
      },
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Getting started', slug: 'getting-started' },
            { label: 'Introduction', slug: 'introduction' },
            { label: 'Concepts', slug: 'concepts' },
            { label: 'Platform limits', slug: 'platform-limits' },
          ],
        },
        {
          label: 'The model',
          items: [
            {
              label: 'Nodes',
              items: [
                { label: 'Overview', slug: 'nodes/overview' },
                { label: 'Falandays', slug: 'nodes/falandays' },
                { label: 'Biological grounding', slug: 'nodes/neurons' },
              ],
            },
            { label: 'Embodiment', slug: 'receptors-effectors' },
            { label: 'Environments & Tasks', slug: 'environments-tasks' },
            { label: 'Task reference', slug: 'task-reference' },
            { label: 'The collective', slug: 'collective' },
          ],
        },
        {
          label: 'Research workflow',
          items: [
            { label: 'Research workflow', slug: 'research-workflow' },
            { label: 'Agentic workflow', slug: 'agentic-workflow' },
            { label: 'Tooling', slug: 'tooling' },
            { label: 'Scoring', slug: 'scoring' },
            { label: 'Analysis', slug: 'analysis' },
            { label: 'Evolution', slug: 'evolution' },
            { label: 'Outputs', slug: 'outputs/overview' },
          ],
        },
        {
          label: 'Experiments',
          items: [
            { label: 'Overview', slug: 'experiments/overview' },
            { label: 'Tracking parameter sweep', slug: 'experiments/tracking-param-sweep' },
            { label: 'Freeze-plasticity onset', slug: 'experiments/freeze-onset' },
            { label: 'Social foraging', slug: 'experiments/social-foraging' },
            { label: 'Criticality across tested perturbations', slug: 'experiments/criticality-control' },
          ],
        },
        {
          label: 'Build & reference',
          items: [
            { label: 'Extending it', slug: 'extending' },
            { label: 'Contracts', slug: 'contracts' },
            { label: 'Reference', slug: 'reference' },
          ],
        },
        {
          label: 'Papers',
          items: [
            { label: 'Overview', slug: 'notes/papers-overview' },
            {
              label: 'Reviews & foundations',
              collapsed: true,
              items: [
                { label: 'Dynamical criticality: overview (Roli et al. 2016)', slug: 'notes/dynamical-criticality-overview' },
                { label: 'Criticality in living systems — review (Muñoz 2018)', slug: 'notes/criticality-living-systems-review' },
                { label: '25 years of self-organized criticality (Watkins et al. 2016)', slug: 'notes/soc-concepts-controversies' },
                { label: 'SOC induced by diversity (Corral et al. 1997)', slug: 'notes/soc-induced-by-diversity' },
              ],
            },
            {
              label: 'Swarm & flock criticality',
              collapsed: true,
              items: [
                { label: 'Swarm criticality & transmission (Vanni 2011)', slug: 'notes/criticality-and-information' },
                { label: 'Finite-size scaling in natural swarms (Attanasi & Cavagna 2014)', slug: 'notes/finite-size-scaling-swarms' },
                { label: 'Extended critical region in swarms (González-Albaladejo & Bonilla 2024)', slug: 'notes/scale-free-chaos-swarms' },
                { label: 'Collective predator evasion (Klamser & Romanczuk 2021)', slug: 'notes/collective-predator-evasion' },
                { label: 'Criticality in collective behavior (Romanczuk & Daniels 2022)', slug: 'notes/phase-transitions-collective-behavior' },
                { label: 'Subcritical escape waves in fish (Poel et al. 2022)', slug: 'notes/subcritical-escape-waves' },
                { label: 'Turning avalanches in schooling fish (Puy et al. 2024)', slug: 'notes/turning-avalanches-fish' },
              ],
            },
            {
              label: 'Engineered & robotic collectives',
              collapsed: true,
              items: [
                { label: 'SOC in an aquatic robot swarm (Zhao et al. 2026)', slug: 'notes/soc-aquatic-robot-swarm' },
                { label: 'Criticality in swarm robots (Lei et al. 2023)', slug: 'notes/criticality-swarm-robots' },
              ],
            },
            {
              label: 'Information & thermodynamic utility',
              collapsed: true,
              items: [
                { label: 'Information flow near criticality (Meijers 2021)', slug: 'notes/information-flow-near-criticality' },
                { label: 'Criticality → collective intelligence (De Vincenzo 2017)', slug: 'notes/criticality-collective-intelligence' },
                { label: 'Thermodynamics of collective motion (Crosato et al. 2018)', slug: 'notes/thermodynamics-collective-motion' },
                { label: 'Why self-organize to criticality (Chen & Prokopenko 2025)', slug: 'notes/why-self-organize-to-criticality' },
                { label: 'Information-based fitness & criticality (Hidalgo et al. 2014)', slug: 'notes/information-based-fitness' },
                { label: 'Spectral radius, criticality & dynamic range (Larremore et al. 2011)', slug: 'notes/spectral-radius-criticality' },
              ],
            },
            {
              label: 'Cross-scale & active matter',
              collapsed: true,
              items: [
                { label: 'Macro-criticality from micro-critical agents (Bessone & Plantec 2026)', slug: 'notes/emergent-macro-criticality' },
                { label: 'Activation fronts in active systems (Gascuel et al. 2024)', slug: 'notes/activation-fronts-active-systems' },
              ],
            },
            {
              label: 'Alternative measures & framing',
              collapsed: true,
              items: [
                { label: 'Heterogeneous criticality in a fish school (Niizato et al. 2024)', slug: 'notes/heterogeneous-criticality-fish-school' },
                { label: 'Cognition as search efficiency (Chis-Ciure & Levin 2025)', slug: 'notes/cognition-all-the-way-down' },
              ],
            },
          ],
        },
      ],
    }),
  ],
});
