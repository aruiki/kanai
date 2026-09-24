import {
  BookOpen,
  Database,
  History,
  Plus,
  ShieldCheck,
  Sparkles,
  Tag,
  Trash2,
  UserRoundPlus,
  X,
} from "lucide-react";
import { useId, useMemo, useState, type FormEvent, type KeyboardEvent } from "react";
import type { LearningState } from "../types";

interface LearningPanelProps {
  learningState: LearningState;
  onLearningStateChange: (state: LearningState) => void;
  onClear: () => void;
  storageAvailable: boolean;
  onNotify: (message: string) => void;
}

function formatRelative(timestamp: number): string {
  const elapsed = Date.now() - timestamp;
  const minutes = Math.max(0, Math.round(elapsed / 60_000));
  if (minutes < 2) return "たった今";
  if (minutes < 60) return `${minutes}分前`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}時間前`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days}日前`;
  return new Intl.DateTimeFormat("ja-JP", { month: "short", day: "numeric" }).format(timestamp);
}

function makeId(): string {
  return `word-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
}

export function LearningPanel({
  learningState,
  onLearningStateChange,
  onClear,
  storageAvailable,
  onNotify,
}: LearningPanelProps) {
  const [tab, setTab] = useState<"dictionary" | "history">("dictionary");
  const [reading, setReading] = useState("");
  const [word, setWord] = useState("");
  const [domainTerm, setDomainTerm] = useState("");
  const wordId = useId();
  const readingId = useId();
  const domainId = useId();

  const learnedEntries = useMemo(
    () =>
      Object.entries(learningState.learned)
        .map(([key, value]) => {
          const [entryReading = "", entryText = ""] = key.split("\u001f");
          return { reading: entryReading, text: entryText, ...value };
        })
        .sort((left, right) => right.lastUsedAt - left.lastUsedAt),
    [learningState.learned],
  );

  const handleAddWord = (event: FormEvent) => {
    event.preventDefault();
    const normalizedReading = reading.trim();
    const normalizedText = word.trim();
    if (!normalizedReading || !normalizedText) return;

    const nextWord = {
      id: makeId(),
      reading: normalizedReading,
      text: normalizedText,
      boost: 180,
      createdAt: Date.now(),
    };
    onLearningStateChange({
      ...learningState,
      userWords: [
        nextWord,
        ...learningState.userWords.filter(
          (item) => !(item.reading === normalizedReading && item.text === normalizedText),
        ),
      ],
    });
    setReading("");
    setWord("");
    onNotify(`「${normalizedText}」をユーザー辞書に追加しました`);
  };

  const handleRemoveWord = (id: string) => {
    onLearningStateChange({
      ...learningState,
      userWords: learningState.userWords.filter((item) => item.id !== id),
    });
    onNotify("ユーザー辞書から削除しました");
  };

  const handleAddDomain = (event: FormEvent) => {
    event.preventDefault();
    const term = domainTerm.trim();
    if (!term || learningState.profile.domainTerms.includes(term)) return;
    onLearningStateChange({
      ...learningState,
      profile: {
        ...learningState.profile,
        domainTerms: [...learningState.profile.domainTerms, term].slice(0, 20),
      },
    });
    setDomainTerm("");
  };

  const toggleLearning = () => {
    const enabled = !learningState.profile.learningEnabled;
    onLearningStateChange({
      ...learningState,
      profile: { ...learningState.profile, learningEnabled: enabled },
    });
    onNotify(enabled ? "ローカル学習を有効にしました" : "新しい学習を停止しました");
  };

  const handleTabKeyDown = (event: KeyboardEvent<HTMLButtonElement>, current: "dictionary" | "history") => {
    let next: "dictionary" | "history" | null = null;
    if (event.key === "ArrowRight" || event.key === "ArrowDown") next = "history";
    if (event.key === "ArrowLeft" || event.key === "ArrowUp") next = "dictionary";
    if (event.key === "Home") next = "dictionary";
    if (event.key === "End") next = "history";
    if (!next || next === current) return;
    event.preventDefault();
    setTab(next);
    const container = event.currentTarget.parentElement;
    window.requestAnimationFrame(() => {
      container?.querySelector<HTMLButtonElement>(`[data-tab="${next}"]`)?.focus();
    });
  };

  return (
    <section className="learning-panel" aria-labelledby="learning-title">
      <div className="panel-heading">
        <div>
          <span className="section-kicker">03 · PERSONALIZE</span>
          <h2 id="learning-title">学習とユーザー辞書</h2>
          <p>選択した変換だけが、このブラウザの個人データになります。</p>
        </div>
        <button
          type="button"
          role="switch"
          aria-checked={learningState.profile.learningEnabled}
          className={`privacy-switch ${learningState.profile.learningEnabled ? "is-on" : ""}`}
          onClick={toggleLearning}
        >
          <span className="switch-track"><span /></span>
          <span>{learningState.profile.learningEnabled ? "学習 ON" : "学習 OFF"}</span>
        </button>
      </div>

      <div className="learning-summary" aria-label="学習状態のサマリー">
        <div><UserRoundPlus size={17} aria-hidden="true" /><strong>{learningState.userWords.length}</strong><span>登録語</span></div>
        <div><Sparkles size={17} aria-hidden="true" /><strong>{learnedEntries.length}</strong><span>学習候補</span></div>
        <div><History size={17} aria-hidden="true" /><strong>{learningState.history.length}</strong><span>履歴</span></div>
        <div className="local-only"><ShieldCheck size={17} aria-hidden="true" /><strong>Local</strong><span>{storageAvailable ? "保存済み" : "保存不可"}</span></div>
      </div>

      <div className="learning-controls">
        <div className="strength-control">
          <div className="control-label">
            <label htmlFor="learning-strength">個人化の強さ</label>
            <output htmlFor="learning-strength">{Math.round(learningState.profile.personalizationStrength * 100)}%</output>
          </div>
          <input
            id="learning-strength"
            type="range"
            min="0"
            max="100"
            step="1"
            value={Math.round(learningState.profile.personalizationStrength * 100)}
            disabled={!learningState.profile.learningEnabled}
            onChange={(event) => {
              const personalizationStrength = Number(event.target.value) / 100;
              onLearningStateChange({
                ...learningState,
                profile: { ...learningState.profile, personalizationStrength },
              });
            }}
          />
          <div className="range-ends"><span>Mozc を優先</span><span>学習を優先</span></div>
        </div>
        <div className="domain-control">
          <label htmlFor={domainId}><Tag size={14} aria-hidden="true" /> 専門語</label>
          <div className="domain-tags">
            {learningState.profile.domainTerms.map((term) => (
              <span key={term}>
                {term}
                <button
                  type="button"
                  onClick={() =>
                    onLearningStateChange({
                      ...learningState,
                      profile: {
                        ...learningState.profile,
                        domainTerms: learningState.profile.domainTerms.filter((item) => item !== term),
                      },
                    })
                  }
                  aria-label={`専門語 ${term} を削除`}
                >
                  <X size={12} aria-hidden="true" />
                </button>
              </span>
            ))}
          </div>
          <form onSubmit={handleAddDomain} className="inline-add">
            <input
              id={domainId}
              value={domainTerm}
              onChange={(event) => setDomainTerm(event.target.value)}
              placeholder="分野名を追加"
            />
            <button type="submit" aria-label="専門語を追加" disabled={!domainTerm.trim()}>
              <Plus size={15} aria-hidden="true" />
            </button>
          </form>
        </div>
      </div>

      <div className="learning-tabs" role="tablist" aria-label="学習データ">
        <button
          type="button"
          role="tab"
          aria-selected={tab === "dictionary"}
          aria-controls="learning-tab-panel"
          tabIndex={tab === "dictionary" ? 0 : -1}
          data-tab="dictionary"
          className={tab === "dictionary" ? "is-active" : ""}
          onClick={() => setTab("dictionary")}
          onKeyDown={(event) => handleTabKeyDown(event, "dictionary")}
        >
          <Database size={15} aria-hidden="true" /> 登録語（優先設定）
          <span>{learningState.userWords.length}</span>
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={tab === "history"}
          aria-controls="learning-tab-panel"
          tabIndex={tab === "history" ? 0 : -1}
          data-tab="history"
          className={tab === "history" ? "is-active" : ""}
          onClick={() => setTab("history")}
          onKeyDown={(event) => handleTabKeyDown(event, "history")}
        >
          <History size={15} aria-hidden="true" /> 学習履歴
          <span>{learningState.history.length}</span>
        </button>
      </div>

      {tab === "dictionary" ? (
        <div id="learning-tab-panel" className="learning-content" role="tabpanel">
          <div className="list-heading">
            <div><BookOpen size={16} aria-hidden="true" /><span>登録した変換（ Mozc候補を優先）</span></div>
            <button
              type="button"
              className="text-action text-action--danger"
              onClick={() => {
                onClear();
                onNotify("学習データと登録語を消去しました");
              }}
              disabled={!learningState.userWords.length && !learnedEntries.length && !learningState.history.length}
            >
              <Trash2 size={14} aria-hidden="true" /> すべて消去
            </button>
          </div>
          <div className="word-list">
            {learningState.userWords.length ? (
              learningState.userWords.map((item) => (
                <div className="word-row" key={item.id}>
                  <div className="word-reading">{item.reading}</div>
                  <div className="word-text"><strong>{item.text}</strong><span>優先 +{Math.round(item.boost)}</span></div>
                  <button type="button" onClick={() => handleRemoveWord(item.id)} aria-label={`${item.text} を削除`}>
                    <Trash2 size={15} aria-hidden="true" />
                  </button>
                </div>
              ))
            ) : (
              <div className="empty-list">まだ登録語はありません。下から最初の変換を追加できます。</div>
            )}
          </div>
          <form className="add-word-form" onSubmit={handleAddWord}>
            <div>
              <label htmlFor={readingId}>読み</label>
              <input id={readingId} value={reading} onChange={(event) => setReading(event.target.value)} placeholder="にほんご" />
            </div>
            <div>
              <label htmlFor={wordId}>表記</label>
              <input id={wordId} value={word} onChange={(event) => setWord(event.target.value)} placeholder="日本語" />
            </div>
            <button type="submit" disabled={!reading.trim() || !word.trim()}>
              <Plus size={15} aria-hidden="true" /> 追加
            </button>
          </form>
        </div>
      ) : (
        <div id="learning-tab-panel" className="learning-content" role="tabpanel">
          <div className="list-heading">
            <div><History size={16} aria-hidden="true" /><span>確定した変換だけを記録</span></div>
            <span className="retention-label">最大 {learningState.profile.historyLimit} 件</span>
          </div>
          <div className="history-list">
            {learningState.history.length ? (
              learningState.history.slice(0, 12).map((item, index) => (
                <div className="history-row" key={`${item.at}-${item.text}-${index}`}>
                  <span className="history-time">{formatRelative(item.at)}</span>
                  <span className="history-reading">{item.reading}</span>
                  <strong>{item.text}</strong>
                </div>
              ))
            ) : (
              <div className="empty-list">候補を確定すると、ここに学習履歴が残ります。</div>
            )}
          </div>
        </div>
      )}
    </section>
  );
}
