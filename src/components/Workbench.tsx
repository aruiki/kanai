import {
  ArrowDown,
  ArrowRight,
  Check,
  CornerDownLeft,
  Gauge,
  Keyboard,
  RotateCcw,
  Sparkles,
  Undo2,
  Zap,
} from "lucide-react";
import {
  useEffect,
  useId,
  useRef,
  useState,
  type ClipboardEvent,
  type KeyboardEvent,
} from "react";
import { ApiError, postCommit, postConvert } from "../api";
import { createDemoResult, MODEL_LABELS } from "../demo";
import type { AiRerankInfo, ConversionCandidate, LearningState } from "../types";

interface WorkbenchProps {
  editorText: string;
  onEditorTextChange: (value: string) => void;
  learningState: LearningState;
  onLearningStateChange: (state: LearningState) => void;
  onApiUnavailable: (message: string) => void;
  onNotify: (message: string) => void;
}

interface InsertionRange {
  start: number;
  end: number;
}

const QUICK_INPUTS = [
  { label: "nihongo", hint: "日本語" },
  { label: "henkan", hint: "変換" },
  { label: "kaihatsu", hint: "開発" },
  { label: "renshuu", hint: "練習" },
];

const ORIGIN_LABELS: Record<string, string> = {
  conversion: "Mozc 文脈変換",
  prediction: "Mozc 予測",
  suggestion: "入力補助",
  userDictionary: "ユーザー辞書",
  userHistory: "学習履歴",
  typingCorrection: "打鍵ミス修復",
  spellingCorrection: "綴り修正",
};

function originKey(candidate: ConversionCandidate): string {
  return typeof candidate.origin === "string" ? candidate.origin : "unknown";
}

function formatElapsed(elapsed: { secs: number; nanos: number }): string {
  const milliseconds = elapsed.secs * 1_000 + elapsed.nanos / 1_000_000;
  return milliseconds < 1 ? `${milliseconds.toFixed(1)} ms` : `${Math.round(milliseconds)} ms`;
}

function formatScore(score: number): string {
  return new Intl.NumberFormat("ja-JP", { maximumFractionDigits: 1 }).format(score);
}

function aiStatusLabel(info: AiRerankInfo): string {
  if (info.status === "applied") return `AI再順位 ${info.changedCandidates}件`;
  if (info.status === "abstained") return "AI見送り";
  if (info.status === "timedOut") return "AIタイムアウト";
  if (info.status === "rejected") return "AI結果を採用せず";
  if (info.status === "unavailable") return "AI未接続";
  return "AI再順位なし";
}

function boundedContext(text: string, maxChars: number, preceding: boolean): string {
  const characters = Array.from(text);
  return (preceding ? characters.slice(-maxChars) : characters.slice(0, maxChars)).join("");
}

function appendAtRange(text: string, range: InsertionRange, insertion: string): string {
  return `${text.slice(0, range.start)}${insertion}${text.slice(range.end)}`;
}

function AdjustmentBar({
  label,
  value,
  ceiling,
  tone,
}: {
  label: string;
  value: number;
  ceiling: number;
  tone: "neutral" | "green" | "orange";
}) {
  const width = value === 0 ? 0 : Math.max(3, Math.min(100, (Math.abs(value) / ceiling) * 100));
  return (
    <div className="adjustment-row">
      <div className="adjustment-copy">
        <span>{label}</span>
        <output>{value > 0 ? `+${formatScore(value)}` : formatScore(value)}</output>
      </div>
      <div className="adjustment-track" aria-hidden="true">
        <span className={`adjustment-fill adjustment-fill--${tone}`} style={{ width: `${width}%` }} />
      </div>
    </div>
  );
}

export function Workbench({
  editorText,
  onEditorTextChange,
  learningState,
  onLearningStateChange,
  onApiUnavailable,
  onNotify,
}: WorkbenchProps) {
  const [romaji, setRomaji] = useState("nihongo");
  const [useContext, setUseContext] = useState(false);
  const [result, setResult] = useState(() => createDemoResult("にほんご"));
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [source, setSource] = useState<"api" | "demo">("demo");
  const [aiInfo, setAiInfo] = useState<AiRerankInfo | null>(null);
  const [isConverting, setIsConverting] = useState(false);
  const [isCommitting, setIsCommitting] = useState(false);
  const [announcement, setAnnouncement] = useState("デモ候補を表示しています");
  const [lastInsertion, setLastInsertion] = useState<{ range: InsertionRange; text: string } | null>(null);
  const [insertionRange, setInsertionRange] = useState<InsertionRange>(() => ({
    start: editorText.length,
    end: editorText.length,
  }));
  const editorRef = useRef<HTMLTextAreaElement>(null);
  const editorRevisionRef = useRef(0);
  const romajiRef = useRef<HTMLInputElement>(null);
  const candidateListRef = useRef<HTMLDivElement>(null);
  const candidateRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const statusId = useId();
  const romajiHintId = useId();

  const selectedCandidate = result.candidates[selectedIndex] ?? result.candidates[0];

  useEffect(() => {
    const list = candidateListRef.current;
    const candidate = candidateRefs.current[selectedIndex];
    if (!list || !candidate) return;
    if (candidate.offsetTop < list.scrollTop) {
      list.scrollTop = candidate.offsetTop;
    } else if (candidate.offsetTop + candidate.offsetHeight > list.scrollTop + list.clientHeight) {
      list.scrollTop = candidate.offsetTop + candidate.offsetHeight - list.clientHeight;
    }
  }, [selectedIndex]);

  const selectRelative = (delta: number) => {
    if (result.candidates.length === 0) return;
    setSelectedIndex((current) => {
      const next = (current + delta + result.candidates.length) % result.candidates.length;
      return next;
    });
  };

  const handleConvert = async () => {
    const reading = romaji.trim();
    if (!reading || isConverting) {
      if (!reading) romajiRef.current?.focus();
      return;
    }

    const editor = editorRef.current;
    const start = editor && editor === document.activeElement ? editor.selectionStart : insertionRange.start;
    const end = editor && editor === document.activeElement ? editor.selectionEnd : insertionRange.end;
    const revision = editorRevisionRef.current;
    setInsertionRange({ start, end });
    setIsConverting(true);
    setAnnouncement("変換しています");

    try {
      const response = await postConvert(
        reading,
        useContext
          ? boundedContext(editorText.slice(0, start), 32, true)
          : "",
        useContext ? boundedContext(editorText.slice(end), 32, false) : "",
        learningState,
      );
      if (revision !== editorRevisionRef.current) {
        setAnnouncement("文書が変更されたため、古い変換結果を表示しませんでした");
        return;
      }
      setResult(response.result);
      setAiInfo(response.ai);
      onLearningStateChange(response.state);
      setSelectedIndex(response.result.focusedIndex ?? 0);
      setSource("api");
      setAnnouncement(`${response.result.candidates.length}件の候補をAPIから取得しました`);
      onNotify(`「${reading}」を ${response.result.provider} で変換しました`);
    } catch (error) {
      if (error instanceof ApiError && error.status >= 400 && error.status < 500) {
        setAnnouncement(`入力を確認してください: ${error.message}`);
        onNotify(error.message);
        return;
      }
      const fallback = createDemoResult(reading);
      setResult(fallback);
      setAiInfo(null);
      setSelectedIndex(0);
      setSource("demo");
      setAnnouncement("ローカルAPIに接続できないため、デモ変換に切り替えました");
      onApiUnavailable(error instanceof Error ? error.message : "ローカルAPIに接続できません");
    } finally {
      setIsConverting(false);
    }
  };

  const handleRomajiKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter") {
      event.preventDefault();
      void handleConvert();
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      selectRelative(1);
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      selectRelative(-1);
    }
  };

  const handleCandidateKeyDown = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    if (event.key === "ArrowDown" || event.key === "ArrowRight") {
      event.preventDefault();
      selectRelative(1);
      candidateRefs.current[(index + 1) % result.candidates.length]?.focus();
    }
    if (event.key === "ArrowUp" || event.key === "ArrowLeft") {
      event.preventDefault();
      const previous = (index - 1 + result.candidates.length) % result.candidates.length;
      setSelectedIndex(previous);
      candidateRefs.current[previous]?.focus();
    }
    if (event.key === "Home") {
      event.preventDefault();
      setSelectedIndex(0);
      candidateRefs.current[0]?.focus();
    }
    if (event.key === "End") {
      event.preventDefault();
      const last = result.candidates.length - 1;
      setSelectedIndex(last);
      candidateRefs.current[last]?.focus();
    }
    if (event.key === "Enter") {
      event.preventDefault();
      void handleCommit(result.candidates[index]);
    }
  };

  const handleCommit = async (candidate: ConversionCandidate) => {
    if (!candidate || isCommitting) return;
    setIsCommitting(true);

    const before = boundedContext(editorText.slice(0, insertionRange.start), 32, true);
    let nextState = learningState;
    const nextText = appendAtRange(editorText, insertionRange, candidate.text);
    const nextCaret = insertionRange.start + candidate.text.length;

    // Commit visible text immediately; API synchronization must never block typing.
    onEditorTextChange(nextText);
    onLearningStateChange(nextState);
    setLastInsertion({ range: insertionRange, text: candidate.text });
    setInsertionRange({ start: nextCaret, end: nextCaret });
    setAnnouncement(`${candidate.text} を文書に挿入しました。学習状態を同期しています`);
    onNotify(`${candidate.text} を確定しました`);
    window.requestAnimationFrame(() => {
      editorRef.current?.focus();
      editorRef.current?.setSelectionRange(nextCaret, nextCaret);
    });

    try {
      const response = await postCommit(
        candidate.id,
        result.revision,
        result.reading,
        candidate.text,
        before,
        learningState,
      );
      nextState = response.state;
      onLearningStateChange(nextState);
      setAnnouncement(`${candidate.text} を文書に挿入し、APIの学習状態を保存しました`);
    } catch {
      setAnnouncement(`${candidate.text} を文書に挿入しました。学習はAPI確認後のみ保存されます`);
    } finally {
      setIsCommitting(false);
    }
  };

  const handleUndo = () => {
    if (!lastInsertion) return;
    const { range, text } = lastInsertion;
    if (editorText.slice(range.start, range.start + text.length) !== text) {
      setAnnouncement("文書が変更されたため、確定の自動元戻しは中止しました");
      setLastInsertion(null);
      return;
    }
    onEditorTextChange(`${editorText.slice(0, range.start)}${editorText.slice(range.start + text.length)}`);
    const caret = range.start;
    setLastInsertion(null);
    setInsertionRange({ start: caret, end: caret });
    setAnnouncement("直前の確定を元に戻しました");
    window.requestAnimationFrame(() => {
      editorRef.current?.focus();
      editorRef.current?.setSelectionRange(caret, caret);
    });
  };

  const handleEditorPaste = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    const pasted = event.clipboardData.getData("text");
    if (/password|パスワード|secret|秘密/iu.test(pasted)) {
      event.preventDefault();
      onNotify("秘密信息的可能性がある貼り付けは入力欄へ取り込みませんでした");
    }
  };

  const scoreCeiling = Math.max(
    1,
    ...(selectedCandidate
      ? Object.values(selectedCandidate.adjustments).map((value) => Math.abs(value))
      : [1]),
  );

  return (
    <section className="workbench" aria-labelledby="workbench-title">
      <div className="editor-pane">
        <div className="section-heading section-heading--editor">
          <div>
            <span className="section-kicker">01 · COMPOSE</span>
            <h2 id="workbench-title">変換ワークベンチ</h2>
          </div>
          <div className={`source-badge source-badge--${source}`}>
            <span className="source-dot" />
            {source === "api" ? "Rust API" : "デモ再生"}
          </div>
        </div>

        <div className="editor-field">
          <div className="field-label-row">
            <label htmlFor="editor-document">編集中の文書</label>
            <span>{editorText.length.toLocaleString("ja-JP")} 文字</span>
          </div>
          <textarea
            id="editor-document"
            ref={editorRef}
            value={editorText}
            onChange={(event) => {
              editorRevisionRef.current += 1;
              onEditorTextChange(event.target.value);
              setInsertionRange({
                start: event.currentTarget.selectionStart,
                end: event.currentTarget.selectionEnd,
              });
            }}
            onPaste={handleEditorPaste}
            onFocus={(event) => {
              setInsertionRange({
                start: event.currentTarget.selectionStart,
                end: event.currentTarget.selectionEnd,
              });
            }}
            onSelect={(event) => {
              const target = event.currentTarget;
              setInsertionRange({ start: target.selectionStart, end: target.selectionEnd });
            }}
            aria-describedby="editor-help"
            spellCheck={false}
            placeholder="変換したい語を、この文書の中に置いてください…"
          />
          <div className="editor-footer" id="editor-help">
            <span><Keyboard size={14} aria-hidden="true" /> カーソル位置へ確定</span>
            <span>Fn + Space でも変換</span>
          </div>
        </div>

        <div className="composition-panel">
          <div className="composition-topline">
            <label htmlFor="romaji-input"><Sparkles size={15} aria-hidden="true" /> Romaji input</label>
            <span id={romajiHintId}><kbd>Enter</kbd> で変換</span>
          </div>
          <div className="composition-row">
            <div className="romaji-shell">
              <span className="romaji-prefix" aria-hidden="true">›</span>
              <input
                id="romaji-input"
                ref={romajiRef}
                value={romaji}
                onChange={(event) => setRomaji(event.target.value)}
                onKeyDown={handleRomajiKeyDown}
                aria-describedby={romajiHintId}
                autoComplete="off"
                autoCapitalize="off"
                spellCheck={false}
              />
              <button
                type="button"
                className="icon-button"
                onClick={() => {
                  setRomaji("");
                  romajiRef.current?.focus();
                }}
                aria-label="入力を消去"
                disabled={!romaji}
              >
                <RotateCcw size={16} aria-hidden="true" />
              </button>
            </div>
            <button
              type="button"
              className="convert-button"
              onClick={() => void handleConvert()}
              disabled={isConverting || !romaji.trim()}
            >
              {isConverting ? <span className="spinner" aria-hidden="true" /> : <Zap size={17} aria-hidden="true" />}
              {isConverting ? "変換中" : "変換"}
              <ArrowRight size={16} aria-hidden="true" />
            </button>
          </div>
          <div className="quick-inputs" aria-label="入力例">
            {QUICK_INPUTS.map((item) => (
              <button
                type="button"
                key={item.label}
                onClick={() => {
                  setRomaji(item.label);
                  romajiRef.current?.focus();
                }}
              >
                <span>{item.label}</span>
                {item.hint}
              </button>
            ))}
          </div>
          <label className={`context-consent ${useContext ? "is-enabled" : ""}`}>
            <input
              type="checkbox"
              checked={useContext}
              onChange={(event) => setUseContext(event.target.checked)}
            />
            <span>周辺の文脈をAIに共有</span>
            <small>カーソル前後を最大32文字に制限</small>
          </label>
        </div>

        <div className="candidate-section">
          <div className="candidate-section-header">
            <div>
              <h3>候補 <span>{result.candidates.length}</span></h3>
              <p>矢印キーで移動、Enter で文書に確定</p>
            </div>
            <div className="candidate-meta">
              <div className="reading-chip">
                <span>読み</span>
                <strong>{result.reading}</strong>
              </div>
              {aiInfo ? (
                <span
                  className={`ai-trace ai-trace--${aiInfo.status}`}
                  title={aiInfo.reasonCode}
                >
                  {aiStatusLabel(aiInfo)}
                </span>
              ) : null}
            </div>
          </div>
          <div
            ref={candidateListRef}
            className="candidate-list"
            role="listbox"
            aria-label="変換候補"
            aria-activedescendant={selectedCandidate ? `candidate-${selectedCandidate.id}` : undefined}
            aria-busy={isConverting}
          >
            {result.candidates.map((item, index) => {
              const origin = originKey(item);
              return (
                <button
                  type="button"
                  role="option"
                  aria-selected={index === selectedIndex}
                  id={`candidate-${item.id}`}
                  className={`candidate-row ${index === selectedIndex ? "is-selected" : ""}`}
                  key={`${item.id}-${item.text}`}
                  ref={(node) => {
                    candidateRefs.current[index] = node;
                  }}
                  onClick={() => setSelectedIndex(index)}
                  onDoubleClick={() => void handleCommit(item)}
                  onKeyDown={(event) => handleCandidateKeyDown(event, index)}
                >
                  <span className="candidate-index">{index + 1}</span>
                  <span className="candidate-main">
                    <strong>{item.text}</strong>
                    <span className="candidate-reading">{item.reading || result.reading}</span>
                  </span>
                  <span className="candidate-tags">
                    {origin === "userDictionary" && <span className="tag tag--accent">辞書</span>}
                    {origin === "userHistory" && <span className="tag">学習</span>}
                    {item.attributes.includes("専門語") && <span className="tag">専門語</span>}
                    {index === selectedIndex && <Check size={15} aria-label="選択中" />}
                  </span>
                </button>
              );
            })}
          </div>
          <button
            type="button"
            className="commit-button"
            onClick={() => selectedCandidate && void handleCommit(selectedCandidate)}
            disabled={!selectedCandidate || isCommitting}
          >
            <CornerDownLeft size={17} aria-hidden="true" />
            {isCommitting ? "学習しています…" : `「${selectedCandidate?.text ?? ""}」を確定`}
            <span>Enter</span>
          </button>
        </div>
      </div>

      <aside className="insight-pane" aria-label="候補の解説と出所">
        <div className="insight-header">
          <div>
            <span className="section-kicker">02 · INSPECT</span>
            <h2>候補の根拠</h2>
          </div>
          <Gauge size={20} aria-hidden="true" />
        </div>

        {selectedCandidate ? (
          <>
            <div className="selected-candidate">
              <div className="selected-candidate-meta">
                <span>選択中 · {originKey(selectedCandidate) === "userDictionary" ? "ユーザー辞書" : "変換候補"}</span>
                <span>#{selectedCandidate.id}</span>
              </div>
              <strong>{selectedCandidate.text}</strong>
              <div className="selected-reading">{selectedCandidate.reading || result.reading}</div>
              <p>{selectedCandidate.description || selectedCandidate.explanation}</p>
            </div>

            <div className="explanation-callout">
              <Sparkles size={16} aria-hidden="true" />
              <div>
                <span>なぜこの順位ですか</span>
                <p>{selectedCandidate.explanation}</p>
              </div>
            </div>

            <div className="score-block">
              <div className="score-heading">
                <span>ランキングスコア</span>
                <output>{formatScore(selectedCandidate.score)}</output>
              </div>
              <AdjustmentBar label="Mozc" value={selectedCandidate.adjustments.mozc} ceiling={scoreCeiling} tone="neutral" />
              <AdjustmentBar label="学習" value={selectedCandidate.adjustments.learning} ceiling={scoreCeiling} tone="green" />
              <AdjustmentBar label="専門語" value={selectedCandidate.adjustments.domain} ceiling={scoreCeiling} tone="orange" />
              <AdjustmentBar label="ユーザー辞書" value={selectedCandidate.adjustments.userWord} ceiling={scoreCeiling} tone="green" />
              <AdjustmentBar label="文脈" value={selectedCandidate.adjustments.context} ceiling={scoreCeiling} tone="orange" />
            </div>

            <div className="provenance">
              <h3>変換ソース</h3>
              <dl>
                <div><dt>Provider</dt><dd>{result.provider}</dd></div>
                <div><dt>Source</dt><dd>{ORIGIN_LABELS[originKey(selectedCandidate)] || "その他"}</dd></div>
                <div><dt>Latency</dt><dd>{formatElapsed(result.elapsed)}</dd></div>
                <div><dt>Model tier</dt><dd>{MODEL_LABELS[learningState.profile.modelTier]}</dd></div>
              </dl>
              {selectedCandidate.log && (
                <div className="trace-line"><span>trace</span><code>{selectedCandidate.log}</code></div>
              )}
            </div>
          </>
        ) : (
          <div className="empty-insight">候補を選択すると、順位の根拠を表示します。</div>
        )}

        <div className="insight-footer">
          <button type="button" onClick={handleUndo} disabled={!lastInsertion}>
            <Undo2 size={15} aria-hidden="true" /> 直前を戻す
          </button>
          <span><ArrowDown size={13} aria-hidden="true" /> リスト内で ↑↓</span>
        </div>
      </aside>

      <p id={statusId} className="sr-only" role="status" aria-live="polite">{announcement}</p>
    </section>
  );
}
