import { generateOpenGraphImage } from 'astro-og-canvas';
import sharp from 'sharp';

const paper: [number, number, number] = [248, 248, 246];
const ink: [number, number, number] = [38, 38, 38];
const fonts = [
  './node_modules/katex/dist/fonts/KaTeX_Main-Regular.ttf',
  './node_modules/katex/dist/fonts/KaTeX_SansSerif-Regular.ttf',
  './src/og/fonts/AtkinsonHyperlegible-Regular.ttf',
];

/** Render the landing design with bundled fonts and the existing credited still. */
export async function homepageImage(): Promise<ArrayBuffer> {
  const card = await generateOpenGraphImage({
    title: 'BrainlessLab',
    description: 'Build a neuron.\nExplore what happens\nwhen neurons interact.',
    logo: { path: './src/assets/brainless-lab-icon.png', size: [48] },
    bgGradient: [paper],
    padding: 72,
    fonts,
    font: {
      title: { color: ink, size: 78, lineHeight: 1.05, families: ['KaTeX_Main'] },
      description: { color: ink, size: 34, lineHeight: 1.35, families: ['KaTeX_SansSerif'] },
    },
  });
  const mask = Buffer.from(`<svg width="630" height="630" xmlns="http://www.w3.org/2000/svg">
    <defs><radialGradient id="fade">
      <stop offset="54%" stop-color="white"/>
      <stop offset="66%" stop-color="white" stop-opacity=".85"/>
      <stop offset="94%" stop-color="white" stop-opacity="0"/>
    </radialGradient></defs>
    <rect width="630" height="630" fill="url(#fade)"/>
  </svg>`);
  const microscopy = await sharp('./public/media/neuron-growth-poster.webp')
    .resize(630, 630)
    .ensureAlpha()
    .composite([{ input: mask, blend: 'dest-in' }])
    .png().toBuffer();
  const credit = await generateOpenGraphImage({
    title: '© Louis Romette & Christophe Leterrier',
    description: 'Aix-Marseille Université / Institut de NeuroPhysioPathologie',
    bgGradient: [paper],
    padding: 0,
    fonts,
    font: {
      title: { color: [75, 75, 75], size: 14, families: ['Atkinson Hyperlegible'] },
      description: { color: [75, 75, 75], size: 12, families: ['Atkinson Hyperlegible'] },
    },
  });
  const attribution = await sharp(Buffer.from(await new Response(credit).arrayBuffer()))
    .extract({ left: 0, top: 0, width: 470, height: 42 }).png().toBuffer();
  const image = await sharp(Buffer.from(await new Response(card).arrayBuffer()))
    .composite([
      { input: microscopy, left: 570, top: 0 },
      { input: attribution, left: 660, top: 550 },
    ])
    .png().toBuffer();
  return new Uint8Array(image).buffer;
}
