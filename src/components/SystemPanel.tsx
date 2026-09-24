import type { KeyboardEvent } from "react";
import {
  Bot,
  Check,
  Cpu,
  Gauge,
  HardDrive,
  LockKeyhole,
  Network,
  RefreshCw,
  Server,
  ShieldCheck,
  TriangleAlert,
  WifiOff,
  Zap,
} from "lucide-react";
import { MODEL_DESCRIPTIONS, MODEL_LABELS } from "../demo";
import type { AppConfig, HardwareCapabilities, ModelTier, ProviderHealth, ServiceState } from "../types";

const MODEL_TIERS: ModelTier[] = ["mozcOnly", "tiny", "compact", "balanced"];

interface SystemPanelProps {
  config: AppConfig;
  system: HardwareCapabilities;
  health: ProviderHealth;
  serviceState: ServiceState;
  modelTier: ModelTier;
  onModelTierChange: (tier: ModelTier) => void;
  onRetry: () => void;
}

function platformName(): string {
  if (typeof navigator === "undefined") return "Browser";
  const value = navigator.userAgent;
  if (/Windows/i.test(value)) return "Windows";
  if (/Mac OS X/i.test(value)) return "macOS";
  if (/Android/i.test(value)) return "Android";
  if (/iPhone|iPad/i.test(value)) return "iOS";
  if (/Linux/i.test(value)) return /WSL/i.test(value) ? "WSL / Linux" : "Linux";
  return "Browser";
}

function isLoopback(endpoint: string): boolean {
  try {
    const hostname = new URL(endpoint).hostname;
    return hostname === "127.0.0.1" || hostname === "localhost" || hostname === "::1";
  } catch {
    return false;
  }
}

export function SystemPanel({
  config,
  system,
  health,
  serviceState,
  modelTier,
  onModelTierChange,
  onRetry,
}: SystemPanelProps) {
  const selectedProfile = config.modelProfiles.find((profile) => profile.tier === modelTier);
  const assistLocal = isLoopback(config.assistantEndpoint);
  const isDemo = serviceState === "offline" || serviceState === "degraded";

  const handleTierKeyDown = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    let nextIndex: number | null = null;
    if (event.key === "ArrowRight" || event.key === "ArrowDown") {
      nextIndex = (index + 1) % MODEL_TIERS.length;
    } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
      nextIndex = (index - 1 + MODEL_TIERS.length) % MODEL_TIERS.length;
    } else if (event.key === "Home") {
      nextIndex = 0;
    } else if (event.key === "End") {
      nextIndex = MODEL_TIERS.length - 1;
    }
    if (nextIndex === null) return;
    event.preventDefault();
    const nextTier = MODEL_TIERS[nextIndex];
    const container = event.currentTarget.parentElement;
    onModelTierChange(nextTier);
    window.requestAnimationFrame(() => {
      container
        ?.querySelector<HTMLButtonElement>(`[data-model-tier="${nextTier}"]`)
        ?.focus();
    });
  };

  return (
    <div className="system-stack">
      <section className="system-panel" aria-labelledby="system-title">
        <div className="panel-heading panel-heading--compact">
          <div>
            <span className="section-kicker">04 · RUNTIME</span>
            <h2 id="system-title">System & architecture</h2>
          </div>
          <button type="button" className="icon-button" onClick={onRetry} aria-label="接続状態を確認">
            <RefreshCw size={16} className={serviceState === "checking" ? "is-spinning" : ""} aria-hidden="true" />
          </button>
        </div>

        <div className={`service-status service-status--${serviceState}`}>
          <span className="service-icon">
            {serviceState === "offline" ? (
              <WifiOff size={18} aria-hidden="true" />
            ) : serviceState === "degraded" ? (
              <TriangleAlert size={18} aria-hidden="true" />
            ) : (
              <Server size={18} aria-hidden="true" />
            )}
          </span>
          <div>
            <strong>
              {serviceState === "checking" && "ローカルAPIを確認中"}
              {serviceState === "online" && "ローカルAPI 接続済み"}
              {serviceState === "degraded" && "API接続・変換機能は降格"}
              {serviceState === "offline" && "デモモードで動作中"}
            </strong>
            <span>
              {isDemo ? "内蔵 fixture を使用 · 操作は引き続き可能" : `${health.provider} · ${health.detail}`}
            </span>
          </div>
          <span className="status-version">v{config.version}</span>
        </div>

        <div className="hardware-heading">
          <span>この環境</span>
          <strong>{platformName()}</strong>
          {isDemo && <em>デモ値</em>}
        </div>
        <div className="hardware-grid">
          <div>
            <HardDrive size={17} aria-hidden="true" />
            <span>メモリ</span>
            <strong>{system.availableRamGib} / {system.totalRamGib} <small>GiB</small></strong>
          </div>
          <div>
            <Cpu size={17} aria-hidden="true" />
            <span>CPU</span>
            <strong>{system.logicalCpus} <small>threads</small></strong>
          </div>
          <div>
            <Gauge size={17} aria-hidden="true" />
            <span>推奨</span>
            <strong>{MODEL_LABELS[system.recommendedTier].split(" · ")[0]}</strong>
          </div>
        </div>

        <div className="model-selector-heading">
          <div>
            <Bot size={17} aria-hidden="true" />
            <span>Assist model</span>
          </div>
          <span>変更は自動保存</span>
        </div>
        <div className="model-options" role="radiogroup" aria-label="AI支援モデルのティア">
          {MODEL_TIERS.map((tier, index) => (
            <button
              type="button"
              role="radio"
              aria-checked={modelTier === tier}
              tabIndex={modelTier === tier ? 0 : -1}
              data-model-tier={tier}
              className={modelTier === tier ? "is-selected" : ""}
              onClick={() => onModelTierChange(tier)}
              onKeyDown={(event) => handleTierKeyDown(event, index)}
              key={tier}
            >
              <span className="model-radio">{modelTier === tier && <Check size={11} aria-hidden="true" />}</span>
              <span><strong>{MODEL_LABELS[tier]}</strong><small>{MODEL_DESCRIPTIONS[tier]}</small></span>
            </button>
          ))}
        </div>
        <div className="model-detail">
          <span>選択中</span>
          <strong>{MODEL_LABELS[modelTier]}</strong>
          <span>
            {selectedProfile
              ? `${selectedProfile.quantization === "notApplicable" ? "モデル不要" : `${selectedProfile.approximateModelMib.toLocaleString()} MiB`} · ${selectedProfile.contextTokens.toLocaleString()} tokens`
              : "Mozc conversion"}
          </span>
        </div>
      </section>

      <section className="architecture-panel" aria-labelledby="architecture-title">
        <div className="panel-heading panel-heading--compact">
          <div>
            <span className="section-kicker">05 · BOUNDARIES</span>
            <h2 id="architecture-title">Architecture & privacy</h2>
          </div>
          <LockKeyhole size={19} aria-hidden="true" />
        </div>

        <div className="architecture-flow" aria-label="データフロー">
          <div><span>UI</span><strong>React workbench</strong></div>
          <i aria-hidden="true" />
          <div><span>Core</span><strong>Rust orchestration</strong></div>
          <i aria-hidden="true" />
          <div><span>Engine</span><strong>Mozc</strong></div>
        </div>
        <div className="assist-flow">
          <Zap size={15} aria-hidden="true" />
          <span>候補再順位は自動・推敲は明示</span>
          <strong>{config.assistantConfigured ? "Assist model ready" : "Rule fallback"}</strong>
          <i aria-hidden="true" />
          <span>{assistLocal ? "loopback" : "configured endpoint"}</span>
        </div>

        <div className={`privacy-status ${assistLocal ? "" : "privacy-status--warning"}`}>
          {assistLocal ? <ShieldCheck size={19} aria-hidden="true" /> : <TriangleAlert size={19} aria-hidden="true" />}
          <div>
            <strong>{assistLocal ? "Local-first privacy" : "Configured AI endpoint"}</strong>
            <span>
              {assistLocal
                ? "AIはローカルループバックへだけ送信されます。"
                : "AI先は明示設定されています。送信先を確認してください。"}
            </span>
          </div>
          <span className="privacy-ok">{assistLocal ? "保護中" : "要確認"}</span>
        </div>
        <ul className="boundary-list">
          <li><Check size={14} aria-hidden="true" /><span><strong>学習</strong> localStorage とローカルAPI状態</span></li>
          <li><Check size={14} aria-hidden="true" /><span><strong>AI assist</strong> 推敲はボタン実行時のみ</span></li>
          <li>
            {assistLocal ? <Check size={14} aria-hidden="true" /> : <TriangleAlert size={14} aria-hidden="true" />}
            <span><strong>Assist target</strong> {assistLocal ? "loopback 限定" : config.assistantEndpoint}</span>
          </li>
        </ul>
        <div className="architecture-foot">
          <Network size={14} aria-hidden="true" />
          <span>Rust API owns conversion · UI owns transparent personal state</span>
        </div>
      </section>
    </div>
  );
}
