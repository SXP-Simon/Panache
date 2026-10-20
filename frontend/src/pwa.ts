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
  updateAvailable: boolean;
  updateId: string;
}

let prompt: InstallPrompt | null = null;
let state: PwaState = {
  updateAvailable: false,
  updateId: '',
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

const deploymentIds = new WeakMap<ServiceWorker, string>();
let deploymentSequence = 0;
function identifyDeployment(worker: ServiceWorker): string {
  let id = deploymentIds.get(worker);
  if (!id) {
    id = `deployment-${++deploymentSequence}`;
    deploymentIds.set(worker, id);
  }
  return id;
}
let studioRegistration: ServiceWorkerRegistration | null = null;
function observeWorker(registration: ServiceWorkerRegistration): void {
  studioRegistration = registration;
  const waiting = () => {
    if (registration.waiting && navigator.serviceWorker.controller)
      update({ updateAvailable: true, updateId: identifyDeployment(registration.waiting) });
  };
  waiting();
  registration.addEventListener('updatefound', () => {
    const installing = registration.installing;
    installing?.addEventListener('statechange', waiting);
  });
}
export async function checkDeploymentUpdate(): Promise<boolean> {
  if (desktop() || !import.meta.env.PROD || !('serviceWorker' in navigator))
    throw new Error('unsupported');
  if (!navigator.onLine) throw new Error('network');
  await registerWorker();
  const registration = studioRegistration;
  if (!registration) throw new Error('unsupported');
  await registration.update();
  const installing = registration.installing;
  if (installing)
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        installing.removeEventListener('statechange', changed);
        reject(new Error('network'));
      }, 20000);
      function changed() {
        if (['installed', 'activated', 'redundant'].includes(installing?.state ?? '')) {
          clearTimeout(timer);
          installing?.removeEventListener('statechange', changed);
          resolve();
        }
      }
      installing.addEventListener('statechange', changed);
      changed();
    });
  if (registration.waiting)
    update({ updateAvailable: true, updateId: identifyDeployment(registration.waiting) });
  return state.updateAvailable;
}
export async function activateDeploymentUpdate(): Promise<void> {
  const waiting = studioRegistration?.waiting;
  if (waiting) {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        navigator.serviceWorker.removeEventListener('controllerchange', changed);
        reject(new Error('network'));
      }, 20000);
      function changed() {
        clearTimeout(timer);
        navigator.serviceWorker.removeEventListener('controllerchange', changed);
        resolve();
      }
      navigator.serviceWorker.addEventListener('controllerchange', changed);
      waiting.postMessage('PANACHE_ACTIVATE_UPDATE');
    });
  }
  window.location.reload();
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
    observeWorker(existing);
    return;
  }
  observeWorker(
    await navigator.serviceWorker.register(new URL('studio-worker.js', scope), {
      scope: scope.href,
      updateViaCache: 'none',
    }),
  );
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
