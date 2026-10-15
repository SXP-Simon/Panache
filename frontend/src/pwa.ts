interface InstallChoice {
  outcome: 'accepted' | 'dismissed';
}
interface InstallPrompt extends Event {
  prompt(): Promise<void>;
  userChoice: Promise<InstallChoice>;
}
export interface PwaState {
  online: boolean;
  installable: boolean;
  installed: boolean;
}

let prompt: InstallPrompt | null = null;
let state: PwaState = {
  online: navigator.onLine,
  installable: false,
  installed: window.matchMedia('(display-mode: standalone)').matches,
};
const subscribers = new Set<() => void>();

function update(values: Partial<PwaState>): void {
  state = { ...state, ...values };
  for (const notify of subscribers) notify();
}
export function getPwaState(): PwaState {
  return state;
}
export function subscribePwa(notify: () => void): () => void {
  subscribers.add(notify);
  return () => subscribers.delete(notify);
}
function desktop(): boolean {
  return Boolean(window.handwritingDesktop) || /\bElectron\//i.test(navigator.userAgent);
}
function isInstallPrompt(event: Event): event is InstallPrompt {
  return (
    'prompt' in event &&
    typeof event.prompt === 'function' &&
    'userChoice' in event &&
    event.userChoice instanceof Promise
  );
}
export async function installPwa(): Promise<void> {
  const available = prompt;
  if (!available || desktop()) return;
  prompt = null;
  update({ installable: false });
  await available.prompt();
  const choice = await available.userChoice;
  if (choice.outcome === 'accepted') update({ installed: true });
}

async function registerWorker(): Promise<void> {
  if (!import.meta.env.PROD || !('serviceWorker' in navigator) || desktop()) return;
  const scope = new URL(import.meta.env.BASE_URL, window.location.href);
  const registrations = await navigator.serviceWorker.getRegistrations();
  const existing = registrations.find((registration) => registration.scope === scope.href);
  if (existing) {
    const script =
      existing.active?.scriptURL ?? existing.waiting?.scriptURL ?? existing.installing?.scriptURL;
    if (!script) return;
    const pathname = new URL(script).pathname;
    if (['service-worker.js', 'sw.js'].some((name) => pathname === new URL(name, scope).pathname)) {
      await existing.update();
      return;
    }
    if (pathname !== new URL('studio-worker.js', scope).pathname) return;
  }
  await navigator.serviceWorker.register(new URL('studio-worker.js', scope), {
    scope: scope.href,
    updateViaCache: 'none',
  });
}

export function initializePwa(): () => void {
  const connectivity = () => update({ online: navigator.onLine });
  const beforeInstall = (event: Event) => {
    if (desktop() || !isInstallPrompt(event)) return;
    event.preventDefault();
    prompt = event;
    update({ installable: true });
  };
  const installed = () => {
    prompt = null;
    update({ installed: true, installable: false });
  };
  window.addEventListener('online', connectivity);
  window.addEventListener('offline', connectivity);
  window.addEventListener('beforeinstallprompt', beforeInstall);
  window.addEventListener('appinstalled', installed);
  void registerWorker().catch(() => undefined);
  return () => {
    window.removeEventListener('online', connectivity);
    window.removeEventListener('offline', connectivity);
    window.removeEventListener('beforeinstallprompt', beforeInstall);
    window.removeEventListener('appinstalled', installed);
  };
}
