import { queryOptions, useQuery } from '@tanstack/react-query';
import * as v from 'valibot';
import { fetchApi, parsePayload, readJson } from './client.ts';

export const catalogKeys = {
  fonts: ['catalog', 'fonts'] as const,
  version: ['catalog', 'version'] as const,
};
export async function getFonts(signal?: AbortSignal): Promise<string[]> {
  return parsePayload(
    v.array(v.string()),
    await readJson(await fetchApi('/api/fonts_info', { signal: signal ?? null })),
  );
}
export async function getVersion(signal?: AbortSignal): Promise<string> {
  return parsePayload(
    v.object({ version: v.string() }),
    await readJson(await fetchApi('/api/version', { signal: signal ?? null })),
  ).version;
}
export const fontsQueryOptions = () =>
  queryOptions({
    queryKey: catalogKeys.fonts,
    queryFn: ({ signal }) => getFonts(signal),
    staleTime: Infinity,
  });
export const versionQueryOptions = () =>
  queryOptions({
    queryKey: catalogKeys.version,
    queryFn: ({ signal }) => getVersion(signal),
    staleTime: Infinity,
  });
export function useFontsQuery() {
  return useQuery(fontsQueryOptions());
}
export function useVersionQuery() {
  return useQuery(versionQueryOptions());
}
