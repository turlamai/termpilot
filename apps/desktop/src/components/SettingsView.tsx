import { useEffect, useRef, useState } from 'react';
import { api, termThemes } from '@termpilot/core';
import { useApp } from '../state/store';
import { confirmDialog } from '../state/feedback';

export default function SettingsView() {
  const presets = useApp((s) => s.presets);
  const refreshPresets = useApp((s) => s.refreshPresets);
  const lang = useApp((s) => s.lang);
  const setLang = useApp((s) => s.setLang);
  const theme = useApp((s) => s.theme);
  const setTheme = useApp((s) => s.setTheme);
  const t = useApp((s) => s.t);

  const [provider, setProvider] = useState('');
  const [model, setModel] = useState('');
  const [baseUrl, setBaseUrl] = useState('');
  const [apiKey, setApiKey] = useState('');
  const [redact, setRedact] = useState(true);
  const [loaded, setLoaded] = useState(false);
  const [saved, setSaved] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<{ ok: boolean; message: string } | null>(null);

  const termThemeId = useApp((s) => s.termThemeId);
  const termFontSize = useApp((s) => s.termFontSize);
  const setTermPrefs = useApp((s) => s.setTermPrefs);
  const fileRef = useRef<HTMLInputElement>(null);
  const [dataMsg, setDataMsg] = useState('');

  const exportData = async () => {
    const data = await api.dataExport();
    const blob = new Blob([JSON.stringify(data, null, 2)], {
      type: 'application/json',
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `termpilot-export-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const importData = async (file: File) => {
    if (!(await confirmDialog(t('settings.import'), { danger: true }))) return;
    try {
      const text = await file.text();
      const r = await api.dataImport(JSON.parse(text));
      setDataMsg(`+${r.hosts} hosts, +${r.snippets} snippets`);
    } catch (e) {
      setDataMsg(String(e).slice(0, 140));
    }
  };

  useEffect(() => {
    void refreshPresets();
    void (async () => {
      try {
        const s = await api.aiSettings();
        setProvider(s.provider);
        setModel(s.model);
        setBaseUrl(s['base-url']);
        setApiKey(s['api-key']); // '' or __SAVED__ sentinel
        setRedact(s['redact-enabled']);
      } catch {
        // backend absent (vite dev); form starts blank
      }
      setLoaded(true);
    })();
  }, [refreshPresets]);

  const pickPreset = (id: string) => {
    setProvider(id);
    const p = presets.find((x) => x.id === id);
    if (p) {
      setModel(p.model);
      setBaseUrl(p['base-url'] ?? '');
    }
  };

  const save = async () => {
    await api.aiSettingsSave({
      provider,
      model,
      'base-url': baseUrl,
      'api-key': apiKey,
      'redact-enabled': redact,
    });
    const s = await api.aiSettings();
    setApiKey(s['api-key']);
    setSaved(true);
    setTimeout(() => setSaved(false), 2000);
  };

  const test = async () => {
    setTesting(true);
    setTestResult(null);
    try {
      const r = await api.aiSettingsTest();
      setTestResult({ ok: r.ok, message: r.message });
    } catch (e) {
      setTestResult({ ok: false, message: String(e) });
    }
    setTesting(false);
  };

  return (
    <div className="settings-view">
      <h2>{t('settings.title')}</h2>

      <section>
        <h3>{t('settings.ai')}</h3>
        {loaded && (
          <div className="form-grid settings-form">
            <label>{t('settings.provider')}</label>
            <select value={provider} onChange={(e) => pickPreset(e.target.value)}>
              {!presets.some((p) => p.id === provider) && provider && (
                <option value={provider}>{provider}</option>
              )}
              {presets.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.label}
                </option>
              ))}
            </select>
            <label>{t('settings.model')}</label>
            <input value={model} onChange={(e) => setModel(e.target.value)} />
            <label>{t('settings.baseurl')}</label>
            <input value={baseUrl} onChange={(e) => setBaseUrl(e.target.value)} />
            <label>{t('settings.apikey')}</label>
            <input
              type="password"
              value={apiKey === '__SAVED__' ? '' : apiKey}
              placeholder={apiKey === '__SAVED__' ? t('settings.apikey.saved') : ''}
              onChange={(e) => setApiKey(e.target.value)}
            />
            <label />
            <label className="check">
              <input
                type="checkbox"
                checked={redact}
                onChange={(e) => setRedact(e.target.checked)}
              />
              {t('settings.redact')}
            </label>
          </div>
        )}
        <div className="row">
          <button className="btn btn-primary" onClick={() => void save()}>
            {t('common.save')}
          </button>
          <button className="btn" disabled={testing} onClick={() => void test()}>
            {t('settings.test')}
          </button>
          {saved && <span className="hint">✓</span>}
          {testResult && (
            <span className={`hint ${testResult.ok ? 'ok' : 'error'}`}>
              {testResult.ok ? t('settings.test.ok') : `${t('settings.test.fail')}: ${testResult.message.slice(0, 120)}`}
            </span>
          )}
        </div>
        <p className="hint">
          {lang === 'zh'
            ? '密钥保存在本地应用数据目录（0600），由 Racket 引擎持有，不进入界面进程。'
            : 'Keys live in the local app data directory (0600), held by the Racket engine — never in the UI process.'}
        </p>
      </section>

      <section>
        <h3>{t('settings.terminal')}</h3>
        <div className="form-grid settings-form">
          <label>{t('settings.termtheme')}</label>
          <select
            value={termThemeId}
            onChange={(e) => setTermPrefs(e.target.value, termFontSize)}
          >
            {termThemes.map((th) => (
              <option key={th.id} value={th.id}>
                {th.label}
              </option>
            ))}
          </select>
          <label>{t('settings.fontsize')}</label>
          <input
            type="number"
            value={termFontSize}
            onChange={(e) =>
              setTermPrefs(termThemeId, Number(e.target.value) || 13)
            }
          />
        </div>
        <div className="row">
          <button className="btn" onClick={() => void exportData()}>
            {t('settings.export')}
          </button>
          <button className="btn" onClick={() => fileRef.current?.click()}>
            {t('settings.import')}
          </button>
          <input
            ref={fileRef}
            type="file"
            accept="application/json"
            style={{ display: 'none' }}
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) void importData(f);
              e.target.value = '';
            }}
          />
          {dataMsg && <span className="hint">{dataMsg}</span>}
        </div>
      </section>

      <section>
        <h3>{t('settings.appearance')}</h3>
        <div className="form-grid settings-form">
          <label>{t('common.language')}</label>
          <select value={lang} onChange={(e) => setLang(e.target.value as 'zh' | 'en')}>
            <option value="zh">简体中文</option>
            <option value="en">English</option>
          </select>
          <label>{t('common.theme')}</label>
          <select value={theme} onChange={(e) => setTheme(e.target.value as 'light' | 'dark' | 'system')}>
            <option value="system">{t('common.system')}</option>
            <option value="light">{t('common.light')}</option>
            <option value="dark">{t('common.dark')}</option>
          </select>
        </div>
      </section>

      <section>
        <h3>{t('settings.about')}</h3>
        <p className="hint">TermPilot v0.1.0 — AGPL-3.0 · termpilot.jrtx.site</p>
      </section>
    </div>
  );
}
