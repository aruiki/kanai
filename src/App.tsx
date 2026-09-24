import {
  BookOpenCheck,
  Bot,
  ChevronDown,
  CircleCheck,
  Cpu,
  LockKeyhole,
  Menu,
  ShieldCheck,
  Sparkles,
  WifiOff,
  X,
} from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { fetchConfig, fetchHealth, fetchSystem } from "./api";
import { AssistDrawer } from "./components/AssistDrawer";
import { LearningPanel } from "./components/LearningPanel";
import { SystemPanel } from "./components/SystemPanel";
import { Workbench } from "./components/Workbench";
import {
  DEMO_CONFIG,
  DEMO_HEALTH,
  DEMO_SYSTEM,
  MODEL_LABELS,
} from "./demo";
import type { AppConfig, HardwareCapabilities, ModelTier, ProviderHealth, ServiceState } from "./types";
import { usePersistentLearning } from "./usePersistentLearning";

const TIERS: ModelTier[] = ["mozcOnly", "tiny", "compact", "balanced"];

function isLoopbackEndpoint(endpoint: string): boolean {
  try {
    const hostname = new URL(endpoint).hostname;
    return hostname === "127.0.0.1" || hostname === "localhost" || hostname === "::1";
  } catch {
    return false;
  }
}

function serviceCopy(state: ServiceState) {
  switch (state) {
    case "checking":
      return { label: "Checking API", detail: "ローカルサービスを確認中", icon: Cpu };
    case "online":
      return { label: "Local API", detail: "Rust core online", icon: CircleCheck };
    case "degraded":
      return { label: "Degraded", detail: "制約付きで動作中", icon: ShieldCheck };
    case "offline":
      return { label: "Demo mode", detail: "Rust API offline", icon: WifiOff };
  }
}

export default function App() {
  const [editorText, setEditorText] = useState(
    "今日の設計メモに、日本語変換の候補と順位の理由を追加します。",
  );
  const [assistOpen, setAssistOpen] = useState(false);
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const [serviceState, setServiceState] = useState<ServiceState>("checking");
  const [serviceDetail, setServiceDetail] = useState("デモ fixture を準備中");
  const [health, setHealth] = useState<ProviderHealth>(DEMO_HEALTH);
  const [system, setSystem] = useState<HardwareCapabilities>(DEMO_SYSTEM);
  const [config, setConfig] = useState<AppConfig>(DEMO_CONFIG);
  const [toast, setToast] = useState("");
  const toastTimer = useRef<number | null>(null);
  const {
    learningState,
    setLearningState,
    clearLearning,
    changeModelTier,
    storageAvailable,
  } = usePersistentLearning();

  const notify = useCallback((message: string) => {
    setToast(message);
    if (toastTimer.current) window.clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(""), 3_600);
  }, []);

  useEffect(
    () => () => {
      if (toastTimer.current) window.clearTimeout(toastTimer.current);
    },
    [],
  );

  const checkServices = useCallback(async () => {
    setServiceState("checking");
    setServiceDetail("ループバック API を照合中");
    try {
      const [nextHealth, nextSystem, nextConfig] = await Promise.all([
        fetchHealth(),
        fetchSystem(),
        fetchConfig(),
      ]);
      setHealth(nextHealth);
      setSystem(nextSystem);
      setConfig(nextConfig);
      if (nextHealth.available) {
        setServiceState("online");
        setServiceDetail(`${nextHealth.provider} · conversion ready`);
      } else {
        setServiceState("degraded");
        setServiceDetail(nextHealth.detail);
      }
    } catch (error) {
      setHealth(DEMO_HEALTH);
      setSystem(DEMO_SYSTEM);
      setConfig(DEMO_CONFIG);
      setServiceState("offline");
      setServiceDetail(error instanceof Error ? error.message : "localhost API に接続できません");
    }
  }, []);

  useEffect(() => {
    void checkServices();
  }, [checkServices]);

  const handleApiUnavailable = useCallback((message: string) => {
    setServiceState("offline");
    setServiceDetail(message);
  }, []);

  const currentService = serviceCopy(serviceState);
  const ServiceIcon = currentService.icon;
  const assistIsLocal = isLoopbackEndpoint(config.assistantEndpoint);

  const handleTierChange = (tier: ModelTier) => {
    changeModelTier(tier);
    notify(`${MODEL_LABELS[tier]} を選択しました`);
  };

  return (
    <div className="app-shell">
      <a className="skip-link" href="#workbench-title">変換ワークベンチへ移動</a>

      <header className="app-header">
        <div className="header-inner">
          <a className="brand" href="#top" aria-label="KanaAI ホーム">
            <span className="brand-mark" aria-hidden="true">
              <span>か</span>
              <i />
            </span>
            <span className="brand-copy"><strong>KanaAI</strong><small>Workbench Developer Beta</small></span>
          </a>

          <nav className={`header-actions ${mobileMenuOpen ? "is-open" : ""}`} aria-label="メインナビゲーション">
            <a href="#learning-title" onClick={() => setMobileMenuOpen(false)}>
              <BookOpenCheck size={15} aria-hidden="true" /> 学習
            </a>
            <a href="#system-title" onClick={() => setMobileMenuOpen(false)}>
              <Cpu size={15} aria-hidden="true" /> System
            </a>
            <div className="header-divider" />
            <label className="header-model-select">
              <span>Model</span>
              <select
                value={learningState.profile.modelTier}
                onChange={(event) => handleTierChange(event.target.value as ModelTier)}
                aria-label="AI支援モデルティア"
              >
                {TIERS.map((tier) => (
                  <option value={tier} key={tier}>{MODEL_LABELS[tier]}</option>
                ))}
              </select>
              <ChevronDown size={13} aria-hidden="true" />
            </label>
            <button type="button" className="assist-header-button" onClick={() => setAssistOpen(true)}>
              <Sparkles size={15} aria-hidden="true" /> AI assist
            </button>
          </nav>

          <div
            className="header-status"
            title={serviceDetail}
            role="status"
            aria-label={`${currentService.label}: ${currentService.detail}`}
          >
            <span className={`status-orb status-orb--${serviceState}`}><ServiceIcon size={14} aria-hidden="true" /></span>
            <span><strong>{currentService.label}</strong><small>{currentService.detail}</small></span>
          </div>

          <button
            type="button"
            className="mobile-menu-button"
            onClick={() => setMobileMenuOpen((value) => !value)}
            aria-expanded={mobileMenuOpen}
            aria-label={mobileMenuOpen ? "メニューを閉じる" : "メニューを開く"}
          >
            {mobileMenuOpen ? <X size={19} aria-hidden="true" /> : <Menu size={19} aria-hidden="true" />}
          </button>
        </div>
      </header>

      <main id="top">
        <section className="hero" aria-labelledby="page-title">
          <div className="hero-copy">
            <span className="hero-eyebrow"><i /> EXPLAINABLE JAPANESE INPUT</span>
            <h1 id="page-title">日本語入りを、<br /><em>理由まで見える</em>形に。</h1>
            <p>Mozc の変換速度と、KanaAI の分かりやすいローカル学習。候補の順序と学習の判断をそのまま確認できます。</p>
          </div>
          <div className="hero-metrics" aria-label="KanaAI の特徴">
            <div><strong>9</strong><span>context candidates</span></div>
            <div><strong>5</strong><span>ranking signals</span></div>
            <div><strong>0</strong><span>cloud sync</span></div>
          </div>
        </section>

        {serviceState !== "online" && (
          <section className={`degraded-banner degraded-banner--${serviceState}`} aria-live="polite">
            <span className="degraded-icon">
              {serviceState === "checking" ? <Cpu size={17} aria-hidden="true" /> : <WifiOff size={17} aria-hidden="true" />}
            </span>
            <div>
              <strong>{serviceState === "checking" ? "Rust API を探索しています" : "API unavailable — demo fallback active"}</strong>
              <p>
                {serviceState === "checking"
                  ? "見つからない場合は、内蔵した日本語変換 fixture へ自動的に切り替えます。"
                  : "変換・候補解説・AI支援はデモ fixture で継続できます。接続が戻ると、/api/convert と /api/assist を自動利用します。"}
              </p>
            </div>
            {serviceState !== "checking" && <button type="button" onClick={() => void checkServices()}>再接続</button>}
          </section>
        )}

        <Workbench
          editorText={editorText}
          onEditorTextChange={setEditorText}
          learningState={learningState}
          onLearningStateChange={setLearningState}
          onApiUnavailable={handleApiUnavailable}
          onNotify={notify}
        />

        <div className="dashboard-grid">
          <LearningPanel
            learningState={learningState}
            onLearningStateChange={setLearningState}
            onClear={clearLearning}
            storageAvailable={storageAvailable}
            onNotify={notify}
          />
          <SystemPanel
            config={config}
            system={system}
            health={health}
            serviceState={serviceState}
            modelTier={learningState.profile.modelTier}
            onModelTierChange={handleTierChange}
            onRetry={() => void checkServices()}
          />
        </div>

        <section className={`privacy-banner ${assistIsLocal ? "" : "privacy-banner--remote"}`} aria-label="プライバシー状態">
          <div className="privacy-banner-icon"><LockKeyhole size={20} aria-hidden="true" /></div>
          <div>
            <span>PRIVACY STATUS</span>
            <h2>{assistIsLocal ? "入力は、この端末の境界を越えません。" : "変換は端末内。AI支援の送信先を確認してください。"}</h2>
          </div>
          <p>
            {assistIsLocal
              ? "変換はローカル Rust コア、学習はこのブラウザ。AI支援もボタンを押したときだけ、表示された内容だけを loopback API へ渡します。"
              : "変換と学習は端末内で完結します。AI支援は実行時に、設定済みの外部モデルへ本文を送信します。"}
          </p>
          <span className="privacy-banner-status">
            <ShieldCheck size={15} aria-hidden="true" /> {assistIsLocal ? "Protected" : "Review endpoint"}
          </span>
        </section>
      </main>

      <footer className="app-footer">
        <div><span className="brand-mark brand-mark--small" aria-hidden="true"><span>か</span><i /></span><strong>KanaAI Workbench</strong></div>
        <p>Mozc conversion foundation · Rust orchestration · local-first personalization</p>
        <span>{serviceState === "online" ? "API connected" : "Demo fixture ready"}</span>
      </footer>

      <button type="button" className="floating-assist" onClick={() => setAssistOpen(true)} aria-label="AI アシストを開く">
        <Bot size={18} aria-hidden="true" />
        <span>AI assist</span>
      </button>

      <AssistDrawer
        open={assistOpen}
        onClose={() => setAssistOpen(false)}
        editorText={editorText}
        learningState={learningState}
        isLocalEndpoint={assistIsLocal}
        onApiUnavailable={handleApiUnavailable}
        onNotify={notify}
      />

      <div className={`toast ${toast ? "is-visible" : ""}`} role="status" aria-live="polite">
        <CircleCheck size={16} aria-hidden="true" />
        <span>{toast}</span>
      </div>
    </div>
  );
}
