import { defineCollection } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';
import { z } from 'astro/zod';
import { existsSync } from 'node:fs';
import { resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = fileURLToPath(new URL('../../', import.meta.url));

const evidenceSchema = z
  .object({
    status: z.enum(['exploratory', 'tuned', 'frozen', 'confirmed', 'promoted', 'retired']),
    id: z.string(),
    protocol_version: z.string(),
    randomization_unit: z.string(),
    n_independent_blocks: z.number().int().nonnegative(),
    block_summary: z.string(),
    primary_endpoint: z.string(),
    artifact_path: z.string(),
    limitations: z.string(),
  })
  .superRefine((evidence, context) => {
    if (['confirmed', 'promoted'].includes(evidence.status)) {
      if (evidence.n_independent_blocks < 1) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['n_independent_blocks'],
          message: 'confirmed and promoted evidence requires at least one independent block',
        });
      }

      const artifact = resolve(repositoryRoot, evidence.artifact_path);
      const insideRepository =
        artifact === repositoryRoot || artifact.startsWith(`${repositoryRoot}${sep}`);
      if (!insideRepository || !existsSync(artifact)) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['artifact_path'],
          message:
            'confirmed and promoted evidence requires an existing repository-relative artifact',
        });
      }
    }
  });

export const collections = {
  docs: defineCollection({
    loader: docsLoader(),
    schema: docsSchema({
      extend: z.object({
        evidence: evidenceSchema.optional(),
      }),
    }),
  }),
};
