import { defineCollection } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';
import { z } from 'astro/zod';
import { existsSync } from 'node:fs';
import { resolve, sep } from 'node:path';

const repositoryRoot = [process.cwd(), resolve(process.cwd(), '..')].find(
  (candidate) =>
    existsSync(resolve(candidate, 'Project.toml')) &&
    existsSync(resolve(candidate, 'site', 'src', 'content.config.ts')),
);

if (!repositoryRoot) {
  throw new Error('cannot locate the BrainlessLab repository root from the site process');
}

const repositoryPathSchema = z
  .string()
  .min(1, 'repository paths must not be empty')
  .superRefine((path, context) => {
    if (path.startsWith('/') || path.split(/[\\/]/).includes('..')) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'repository paths must be relative and may not traverse outside the repository',
      });
      return;
    }

    const target = resolve(repositoryRoot, path);
    const insideRepository =
      target === repositoryRoot || target.startsWith(`${repositoryRoot}${sep}`);
    if (!insideRepository || !existsSync(target)) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: `repository path does not exist: ${path}`,
      });
    }
  });

const corePageSchema = z
  .string()
  .regex(
    /^\/core\/[a-z0-9]+(?:-[a-z0-9]+)*\/$/,
    'core_page must be a canonical /core/<slug>/ route',
  )
  .superRefine((route, context) => {
    const relative = route.slice(1, -1);
    const candidates = [
      resolve(repositoryRoot, 'site', 'src', 'content', 'docs', `${relative}.mdx`),
      resolve(repositoryRoot, 'site', 'src', 'content', 'docs', relative, 'index.mdx'),
    ];
    if (!candidates.some(existsSync)) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: `core_page does not resolve to a documentation page: ${route}`,
      });
    }
  });

const experimentalSchema = z
  .object({
    family: z.enum([
      'reservoirs',
      'embodiment',
      'worlds-tasks',
      'collectives',
      'analyses',
      'evolution',
    ]),
    readiness: z.enum(['available', 'integrated']),
    tags: z
      .array(
        z
          .string()
          .regex(
            /^[a-z0-9]+(?:-[a-z0-9]+)*$/,
            'experimental tags must be lowercase kebab-case',
          ),
      )
      .min(1),
    core_page: corePageSchema,
    source_paths: z.array(repositoryPathSchema).min(1),
    example_paths: z.array(repositoryPathSchema).default([]),
    test_paths: z.array(repositoryPathSchema).default([]),
  })
  .superRefine((feature, context) => {
    if (new Set(feature.tags).size !== feature.tags.length) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['tags'],
        message: 'experimental tags must be unique',
      });
    }
    if (feature.readiness === 'integrated') {
      if (feature.example_paths.length === 0) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['example_paths'],
          message: 'integrated experimental features require an executable or configured example',
        });
      }
      if (feature.test_paths.length === 0) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['test_paths'],
          message: 'integrated experimental features require focused test evidence',
        });
      }
    }
  });

export const collections = {
  docs: defineCollection({
    loader: docsLoader(),
    schema: docsSchema({
      extend: z.object({
        experimental: experimentalSchema.optional(),
      }),
    }),
  }),
};
