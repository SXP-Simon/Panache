import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from 'react';
import brandIcon from './assets/brand.svg';
import { AnimatePresence, motion, MotionConfig, useReducedMotion } from 'motion/react';
import { I18nContext, translate, useI18n } from './i18n';
import type { MessageKey } from './i18n';
import { getPwaState, subscribePwa, installPwa } from './pwa';
import { usePreferencesStore } from './features/preferences/store';
import { reportFailure } from './features/workspace/reportFailure';
import WorkspaceStatus from './components/WorkspaceStatus';
import WorkspaceFooter from './components/WorkspaceFooter';
import GenerateButton from './components/GenerateButton';
import EditorPanel from './components/EditorPanel';
import SettingsPanel from './components/SettingsPanel';
import PreviewPanel from './components/PreviewPanel';
import Button from './shared/ui/Button';
import Modal from './shared/ui/Modal';
import { Languages, Moon, Sun, CircleHelp, MonitorDown, ArrowUpRight } from './shared/icons';
export default function App() {
  const locale = usePreferencesStore((state) => state.locale);
  const toggleLocale = usePreferencesStore((state) => state.toggleLocale);
  const t = useCallback((key: MessageKey) => translate(locale, key), [locale]);
  const value = useMemo(() => ({ locale, t, toggle: toggleLocale }), [locale, t, toggleLocale]);
  useEffect(() => {
    document.documentElement.lang = locale === 'cn' ? 'zh-CN' : 'en';
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
  const pwa = useSyncExternalStore(subscribePwa, getPwaState);
  const [guide, setGuide] = useState(false);
  const [desktop, setDesktop] = useState(false);
  const theme = usePreferencesStore((state) => state.theme);
  const toggleTheme = usePreferencesStore((state) => state.toggleTheme);
  const dark = theme === 'dark';
  useEffect(() => {
    document.documentElement.dataset['theme'] = dark ? 'dark' : 'light';
  }, [dark]);
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
                void installPwa().catch(reportFailure);
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
            onClick={toggleTheme}
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
          <GenerateButton testId="preview-btn" />
        </div>
        <WorkspaceStatus />
        <div className="workspace-grid" data-testid="workspace">
          <EditorPanel />
          <PreviewPanel />
          <SettingsPanel />
        </div>
        <WorkspaceFooter />
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
