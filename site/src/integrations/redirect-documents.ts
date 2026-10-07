import { readFile, writeFile } from 'node:fs/promises';
import type { AstroIntegration } from 'astro';

/** Complete Astro's minimal redirect HTML before Starlight runs Pagefind. */
export default function redirectDocuments(): AstroIntegration {
  return {
    name: 'brainlesslab-redirect-documents',
    hooks: {
      'astro:build:done': async ({ routes }) => {
        for (const route of routes) {
          if (route.type !== 'redirect') continue;
          for (const file of route.distURL ?? []) {
            const html = await readFile(file, 'utf8');
            if (/<html[\s>]/i.test(html)) continue;
            // Preserve Astro's refresh, canonical URL, noindex and fallback link.
            const bodyStart = html.indexOf('<body>');
            if (bodyStart === -1) {
              throw new Error(`Redirect document has no body: ${file.pathname}`);
            }
            const head = html.slice(0, bodyStart).replace(/^<!doctype html>/i, '');
            const body = html.slice(bodyStart);
            await writeFile(file, `<!doctype html><html lang="en"><head>${head}</head>${body}</html>`);
          }
        }
      },
    },
  };
}
