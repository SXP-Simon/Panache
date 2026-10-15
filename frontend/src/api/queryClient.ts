import { QueryClient } from '@tanstack/react-query';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: { retry: false, refetchOnWindowFocus: false },
    mutations: { retry: false },
  },
});

queryClient.setQueryDefaults(['generation', 'active'], { gcTime: Infinity, staleTime: Infinity });
