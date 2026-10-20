import { useUpdatesStore } from './features/updates/store';
import UpdatePrompt from './features/updates/UpdatePrompt';
import UpdateSettings from './features/updates/UpdateSettings';
import { useInitializeUpdates } from './features/updates/runtime';
import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from 'react';
import ThemeColorEditor from './features/preferences/ThemeColorEditor';
import { applyThemeColor } from './features/preferences/themeColors';
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
import GitHubIcon from './shared/ui/GitHubIcon';
import {
  Languages,
  Moon,
  Sun,
  CircleHelp,
  MonitorDown,
  ArrowUpRight,
  SlidersHorizontal,
} from './shared/icons';
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
  const updatePrompt = useUpdatesStore((state) => state.prompt);
  const { locale, t, toggle } = useI18n();
  const reduced = useReducedMotion();
  const pwa = useSyncExternalStore(subscribePwa, getPwaState);
  const [appearance, setAppearance] = useState(false);
  const themeColor = usePreferencesStore((state) => state.themeColor);
  const [guide, setGuide] = useState(false);
  const [desktop, setDesktop] = useState(false);
  useInitializeUpdates(appearance || guide || desktop);
  const theme = usePreferencesStore((state) => state.theme);
  const toggleTheme = usePreferencesStore((state) => state.toggleTheme);
  const dark = theme === 'dark';
  useEffect(() => {
    document.documentElement.dataset['theme'] = dark ? 'dark' : 'light';
    applyThemeColor(themeColor, dark);
  }, [dark, themeColor]);
  return (
    <div className="app-shell">
      <header className="app-header" data-testid="app-header">
        <div className="brand">
          <span className="brand-mark">
            <img src={brandIcon} width={38} height={38} alt="" aria-hidden="true" />
          </span>
          <span>
            <a className="brand-home" href="/" data-testid="brand-title">
              {t('app')}
            </a>
            <a
              className="project-source-link"
              href="https://github.com/SXP-Simon/Panache"
              target="_blank"
              rel="noopener noreferrer"
              data-testid="project-source-link"
              aria-label={`${t('projectSource')}: SXP-Simon/Panache`}
            >
              <GitHubIcon />
              <span>SXP-Simon/Panache</span>
            </a>
          </span>
        </div>
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
          <Button
            variant="ghost"
            size="small"
            data-testid="appearance-btn"
            onClick={() => setAppearance(true)}
          >
            <SlidersHorizontal size={18} />
            {t('appearance')}
          </Button>
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
          <div className="workspace-actions">
            <Button
              className="mobile-settings-button"
              variant="ghost"
              data-testid="mobile-settings-btn"
              onClick={() => setAppearance(true)}
            >
              {t('appearance')}
            </Button>
            <GenerateButton testId="preview-btn" />
          </div>
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
        {updatePrompt && <UpdatePrompt key={updatePrompt.key} prompt={updatePrompt} />}
        {appearance && (
          <Modal
            key="appearance"
            title={t('appearance')}
            closeLabel={t('close')}
            testId="appearance-modal"
            onClose={() => setAppearance(false)}
          >
            <ThemeColorEditor />
            <UpdateSettings />
            <div className="appearance-tools">
              <Button variant="secondary" data-testid="settings-language-toggle" onClick={toggle}>
                <Languages size={16} />
                {locale === 'cn' ? 'English' : '简体中文'}
              </Button>
              <Button variant="secondary" data-testid="settings-theme-toggle" onClick={toggleTheme}>
                {dark ? <Sun size={16} /> : <Moon size={16} />}
                {t('theme')}
              </Button>
              <Button
                variant="ghost"
                data-testid="settings-guide-btn"
                onClick={() => {
                  setAppearance(false);
                  setGuide(true);
                }}
              >
                <CircleHelp size={16} />
                {t('help')}
              </Button>
              <Button
                variant="ghost"
                data-testid="settings-desktop-download-btn"
                onClick={() => {
                  setAppearance(false);
                  setDesktop(true);
                }}
              >
                <MonitorDown size={16} />
                {t('desktop')}
              </Button>
              {pwa.installable && (
                <Button
                  variant="ghost"
                  data-testid="settings-pwa-install-btn"
                  onClick={() => {
                    void installPwa().catch(reportFailure);
                  }}
                >
                  {t('installApp')}
                </Button>
              )}
            </div>
            <a
              className="project-source-link"
              href="https://github.com/SXP-Simon/Panache"
              target="_blank"
              rel="noopener noreferrer"
              data-testid="settings-project-source-link"
            >
              <GitHubIcon />
              <span>SXP-Simon/Panache</span>
            </a>
          </Modal>
        )}
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
                href="https://github.com/SXP-Simon/Panache/releases"
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
