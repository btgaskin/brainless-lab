import { getCollection } from 'astro:content';
import { OGImageRoute } from 'astro-og-canvas';

const entries = await getCollection('docs');

const pages = Object.fromEntries(
  entries.map(({ id, data }) => [id || 'index', data]),
);

const truncate = (value: string | undefined, maxLength = 160) => {
  const characters = Array.from(value ?? '');
  if (characters.length <= maxLength) return value;
  return `${characters.slice(0, maxLength - 1).join('').trimEnd()}…`;
};

export const { getStaticPaths, GET } = await OGImageRoute({
  pages,
  // The route filename supplies `.png`; keep the dynamic parameter extension-free.
  getSlug: (path) => path,
  getImageOptions: (_path, page) => ({
    title: page.title,
    description: truncate(page.description),
    logo: {
      path: './src/assets/brainless-lab-icon.png',
      size: [96],
    },
    bgGradient: [
      [47, 111, 94],
      [32, 31, 28],
    ],
    border: {
      color: [125, 196, 172],
      width: 10,
      side: 'inline-start',
    },
    padding: 64,
    // Keep documentation builds deterministic and usable offline. KaTeX is an
    // existing site dependency, so its bundled sans font is available after
    // the ordinary frozen install without a build-time network request.
    fonts: ['./node_modules/katex/dist/fonts/KaTeX_SansSerif-Regular.ttf'],
    font: {
      title: {
        color: [246, 243, 234],
        size: 68,
        lineHeight: 1.05,
        families: ['KaTeX_SansSerif'],
      },
      description: {
        color: [236, 232, 223],
        size: 34,
        lineHeight: 1.25,
        families: ['KaTeX_SansSerif'],
      },
    },
  }),
});
