import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from 'react';
import brandIcon from './assets/brand.svg';
import { AnimatePresence, motion, MotionConfig, useReducedMotion } from 'motion/react';
import { I18nContext, translate, useI18n } from './i18n';
import type { Locale, MessageKey } from './i18n';
import { getPwaState, subscribePwa, installPwa } from './pwa';
import { useWorkspace } from './composables/useWorkspace';
import EditorPanel from './components/EditorPanel';
import SettingsPanel from './components/SettingsPanel';
import PreviewPanel from './components/PreviewPanel';
import Button from './shared/ui/Button';
import Modal from './shared/ui/Modal';
import AnimatedReveal from './shared/ui/AnimatedReveal';
import {
  Languages,
  Moon,
  Sun,
  CircleHelp,
  MonitorDown,
  Eye,
  LoaderCircle,
  Check,
  AlertCircle,
  FolderOpen,
  ArrowUpRight,
} from './shared/icons';
function preferredLocale(): Locale {
  try {
    return localStorage.getItem('studio.locale') === 'en' ? 'en' : 'cn';
  } catch {
    return 'cn';
  }
}
function preferredTheme() {
  try {
    return localStorage.getItem('studio.theme') === 'dark';
  } catch {
    return false;
  }
}
export default function App() {
  const [locale, setLocale] = useState<Locale>(preferredLocale);
  const t = useCallback((key: MessageKey) => translate(locale, key), [locale]);
  const value = useMemo(
    () => ({ locale, t, toggle: () => setLocale((current) => (current === 'cn' ? 'en' : 'cn')) }),
    [locale, t],
  );
  useEffect(() => {
    document.documentElement.lang = locale === 'cn' ? 'zh-CN' : 'en';
    try {
      localStorage.setItem('studio.locale', locale);
    } catch {
      /* Language remains available without storage. */
    }
  }, [locale]);
  return (
    <I18nContext.Provider value={value}>
      <MotionConfig
        reducedMotion="user"
        transition={{ type: 'spring', stiffness: 300, damping: 25 }}
      >
        <Studio />
      </MotionConfig>
    </I18nContext.Provider>
  );
}
function Studio() {
  const { locale, t, toggle } = useI18n();
  const reduced = useReducedMotion();
  const w = useWorkspace();
  const pwa = useSyncExternalStore(subscribePwa, getPwaState);
  const [guide, setGuide] = useState(false);
  const [desktop, setDesktop] = useState(false);
  const [dark, setDark] = useState(preferredTheme);
  useEffect(() => {
    document.documentElement.dataset['theme'] = dark ? 'dark' : 'light';
    try {
      localStorage.setItem('studio.theme', dark ? 'dark' : 'light');
    } catch {
      /* Theme remains available without storage. */
    }
  }, [dark]);
  const status =
    w.error ||
    (w.retrySeconds > 0 ? `${t('queueBusy')} ${w.retrySeconds} ${t('queueSuffix')}` : w.notice);
  return (
    <div className="app-shell">
      <header className="app-header">
        <a className="brand" href="/" aria-label={t('app')}>
          <span className="brand-mark">
            <img src={brandIcon} alt="" aria-hidden="true" />
          </span>
          <span>
            <strong>{t('app')}</strong>
            <small>HANDWRITING STUDIO</small>
          </span>
        </a>
        <nav className="header-nav">
          <span className="nav-active">{t('workspace')}</span>
          <Button
            variant="ghost"
            size="small"
            data-testid="guide-btn"
            onClick={() => setGuide(true)}
          >
            <CircleHelp size={16} />
            {t('help')}
          </Button>
          <Button
            variant="ghost"
            size="small"
            data-testid="desktop-download-btn"
            onClick={() => setDesktop(true)}
          >
            <MonitorDown size={16} />
            {t('desktop')}
          </Button>
        </nav>
        <div className="header-actions">
          {pwa.installable && (
            <Button
              variant="ghost"
              size="small"
              data-testid="pwa-install-btn"
              onClick={() => {
                void installPwa().catch(w.fail);
              }}
            >
              <MonitorDown size={16} />
              {t('installApp')}
            </Button>
          )}
          <Button
            variant="ghost"
            size="icon"
            data-testid="language-toggle"
            aria-label={t('language')}
            title={locale === 'cn' ? 'English' : '简体中文'}
            onClick={toggle}
          >
            <Languages size={18} />
          </Button>
          <Button
            variant="ghost"
            size="icon"
            data-testid="theme-toggle"
            aria-label={t('theme')}
            onClick={() => setDark(!dark)}
          >
            {dark ? <Sun size={18} /> : <Moon size={18} />}
          </Button>
        </div>
      </header>
      <motion.main
        className="workspace-content"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: reduced ? 0 : 0.2 }}
      >
        <div className="workspace-intro">
          <div>
            <p className="eyebrow">
              <span className="live-dot" />
              {t('workspace')}
            </p>
            <h1>{t('tagline')}</h1>
          </div>
          <Button
            variant="primary"
            data-testid="preview-btn"
            disabled={w.disabled}
            onClick={() => void w.generate('preview')}
          >
            {w.busy ? <LoaderCircle className="spin" size={17} /> : <Eye size={17} />}{' '}
            {t('previewAction')}
          </Button>
        </div>
        <AnimatePresence initial={false}>
          {!pwa.online && (
            <AnimatedReveal key="offline">
              <div className="status-message" role="status" data-testid="offline-notice">
                <AlertCircle size={17} />
                <span>{t('offlineNotice')}</span>
              </div>
            </AnimatedReveal>
          )}
          {status && (
            <AnimatedReveal key="status">
              <div
                className={`status-message ${w.error ? 'status-message--error' : ''}`}
                role="status"
                aria-live="polite"
                data-testid="message-info"
              >
                {w.error ? (
                  <AlertCircle size={17} />
                ) : w.busy ? (
                  <LoaderCircle className="spin" size={17} />
                ) : (
                  <Check size={17} />
                )}
                <span>{status}</span>
              </div>
            </AnimatedReveal>
          )}
          {w.savedPath && (
            <AnimatedReveal key="download">
              <div className="download-hint" data-testid="download-saved-hint">
                <span data-testid="download-saved-path">{w.savedPath}</span>
                <Button
                  size="small"
                  variant="ghost"
                  data-testid="reveal-download-btn"
                  onClick={() => window.handwritingDesktop?.revealLastDownload()}
                >
                  <FolderOpen size={15} />
                  {t('openFolder')}
                </Button>
              </div>
            </AnimatedReveal>
          )}
        </AnimatePresence>
        {w.pdfBytes > 0 && (
          <span data-testid="pdf-download-bytes" hidden>
            {w.pdfBytes}
          </span>
        )}
        <div className="workspace-grid" data-testid="workspace">
          <EditorPanel workspace={w} />
          <PreviewPanel workspace={w} />
          <SettingsPanel workspace={w} />
        </div>
        <footer className="app-footer">
          <span>
            <span className="local-dot" />
            {t('localDraft')}
          </span>
          <span>
            {t('app')}
            {w.version && (
              <span>
                {' '}
                · <span data-testid="app-version">v{w.version}</span>
              </span>
            )}
          </span>
        </footer>
      </motion.main>
      <AnimatePresence>
        {guide && (
          <Modal
            key="guide"
            title={t('guideTitle')}
            closeLabel={t('close')}
            onClose={() => setGuide(false)}
          >
            <p className="help-text">{t('guideText')}</p>
            <p className="privacy-note">{t('privacy')}</p>
            <footer className="modal-actions">
              <Button variant="primary" onClick={() => setGuide(false)}>
                {t('close')}
              </Button>
            </footer>
          </Modal>
        )}
        {desktop && (
          <Modal
            key="desktop"
            title={t('desktop')}
            closeLabel={t('close')}
            onClose={() => setDesktop(false)}
          >
            <p className="help-text">{t('desktopHint')}</p>
            <footer className="modal-actions">
              <a
                className="button button--primary"
                href="https://github.com/SXP-Simon/handwriting-web/releases"
                target="_blank"
                rel="noopener noreferrer"
              >
                {t('viewReleases')}
                <ArrowUpRight size={16} />
              </a>
            </footer>
          </Modal>
        )}
      </AnimatePresence>
    </div>
  );
}
