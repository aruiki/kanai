import {
  Bot,
  Check,
  ChevronRight,
  Copy,
  Info,
  LoaderCircle,
  LockKeyhole,
  Send,
  ShieldCheck,
  Sparkles,
  X,
} from "lucide-react";
import { useEffect, useId, useRef, useState, type FormEvent, type KeyboardEvent } from "react";
import { postAssist } from "../api";
import { demoAssist } from "../demo";
import type { AssistResponse, LearningState } from "../types";

interface AssistDrawerProps {
  open: boolean;
  onClose: () => void;
  editorText: string;
  learningState: LearningState;
  isLocalEndpoint: boolean;
  onApiUnavailable: (message: string) => void;
  onNotify: (message: string) => void;
}

const INSTRUCTIONS = [
  { id: "concise", label: "簡潔にまとめる", hint: "要点を抽出" },
  { id: "bullets", label: "箇条書きにする", hint: "読みやすく整理" },
  { id: "polite", label: "丁寧にする", hint: "敬表現で統一" },
  { id: "organize", label: "構成を見直す", hint: "書き出し案" },
];

const DEMO_RESPONSE: AssistResponse = {
  text: "",
  provider: "demo-local-rules",
  notice: "ローカルAPIへ接続できないため、ブラウザ内の簡易ルールで処理しました。",
};

export function AssistDrawer({
  open,
  onClose,
  editorText,
  learningState,
  isLocalEndpoint,
  onApiUnavailable,
  onNotify,
}: AssistDrawerProps) {
  const [text, setText] = useState("");
  const [instruction, setInstruction] = useState(INSTRUCTIONS[0].label);
  const [personalize, setPersonalize] = useState(true);
  const [result, setResult] = useState<AssistResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const textId = useId();
  const resultId = useId();
  const textRef = useRef<HTMLTextAreaElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!open) return;
    const returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const frame = window.requestAnimationFrame(() => textRef.current?.focus());
    return () => {
      window.cancelAnimationFrame(frame);
      document.body.style.overflow = previousOverflow;
      returnFocus?.focus();
    };
  }, [open]);

  useEffect(() => {
    if (open && !text.trim() && editorText.trim()) {
      setText(editorText.slice(0, 4_000));
      setResult(null);
    }
  }, [editorText, open]);

  if (!open) return null;

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();
    const trimmed = text.trim();
    if (!trimmed || loading) return;
    setLoading(true);
    setResult(null);

    try {
      const response = await postAssist(trimmed, instruction, personalize, learningState);
      setResult(response);
      if (response.notice) onNotify(response.notice);
    } catch (error) {
      setResult({
        ...DEMO_RESPONSE,
        text: demoAssist(trimmed, instruction),
      });
      onApiUnavailable(error instanceof Error ? error.message : "ローカルAPIに接続できません");
    } finally {
      setLoading(false);
    }
  };

  const handleDialogKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      onClose();
      return;
    }
    if (event.key !== "Tab") return;
    const focusable = Array.from(
      event.currentTarget.querySelectorAll<HTMLElement>(
        'button:not([disabled]), textarea:not([disabled]), input:not([disabled]), [tabindex="0"]',
      ),
    );
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  };

  return (
    <div className="drawer-backdrop" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div
        className="assist-drawer"
        role="dialog"
        aria-modal="true"
        aria-labelledby="assist-title"
        aria-describedby="assist-description"
        onKeyDown={handleDialogKeyDown}
      >
        <header className="drawer-header">
          <div className="drawer-title-icon"><Sparkles size={19} aria-hidden="true" /></div>
          <div>
            <span>LOCAL WRITING ASSIST</span>
            <h2 id="assist-title">AI アシスト</h2>
          </div>
          <button ref={closeRef} type="button" className="icon-button" onClick={onClose} aria-label="AIアシストを閉じる">
            <X size={19} aria-hidden="true" />
          </button>
        </header>

        <div className="drawer-intro" id="assist-description">
          <p>
            {isLocalEndpoint
              ? "本文をループバックへ送り、選んだ形式に整えます。実行しない限り、 assist API には送信されません。"
              : "本文を設定されたAI送信先へ送ります。実行前に送信先を確認し、実行しない限り送信されません。"}
          </p>
          <span><ShieldCheck size={14} aria-hidden="true" /> Local-first</span>
        </div>

        <form className="assist-form" onSubmit={(event) => void handleSubmit(event)}>
          <div className="assist-field">
            <div className="field-label-row">
              <label htmlFor={textId}>対象テキスト</label>
              <span>{text.length.toLocaleString("ja-JP")} / 4,000</span>
            </div>
            <textarea
              id={textId}
              ref={textRef}
              value={text}
              maxLength={4_000}
              onChange={(event) => {
                setText(event.target.value);
                if (result) setResult(null);
              }}
              placeholder="推敲したい日本語を入力…"
            />
          </div>

          <fieldset className="instruction-field">
            <legend>支援方法</legend>
            <div className="instruction-options">
              {INSTRUCTIONS.map((item) => (
                <button
                  type="button"
                  className={instruction === item.label ? "is-selected" : ""}
                  onClick={() => setInstruction(item.label)}
                  aria-pressed={instruction === item.label}
                  key={item.id}
                >
                  <span>{instruction === item.label && <Check size={12} aria-hidden="true" />}</span>
                  <div><strong>{item.label}</strong><small>{item.hint}</small></div>
                </button>
              ))}
            </div>
          </fieldset>

          <button
            type="button"
            role="switch"
            aria-checked={personalize}
            className={`personalize-switch ${personalize ? "is-on" : ""}`}
            onClick={() => setPersonalize((value) => !value)}
          >
            <span><Bot size={16} aria-hidden="true" /> 学習した専門語を反映</span>
            <span className="switch-track"><span /></span>
          </button>

          <div className="payload-note">
            <LockKeyhole size={15} aria-hidden="true" />
            <p>
              このリクエストには、選択した本文・指示{personalize && "・専門語設定"}を含みます。KanaAI API の設定済みモデルへだけ渡します。
            </p>
            <Info size={14} aria-hidden="true" />
          </div>

          <button type="submit" className="assist-submit" disabled={!text.trim() || loading}>
            {loading ? <LoaderCircle size={17} className="is-spinning" aria-hidden="true" /> : <Send size={17} aria-hidden="true" />}
            {loading ? (isLocalEndpoint ? "ローカルモデルで処理中…" : "AI送信先で処理中…") : "AI支援を実行"}
            {!loading && <ChevronRight size={16} aria-hidden="true" />}
          </button>
        </form>

        <section className="assist-result" aria-labelledby={resultId} aria-live="polite">
          <div className="result-heading">
            <div><Sparkles size={15} aria-hidden="true" /><h3 id={resultId}>支援結果</h3></div>
            {result && (
              <button
                type="button"
                onClick={async () => {
                  try {
                    await navigator.clipboard.writeText(result.text);
                    onNotify("結果をコピーしました");
                  } catch {
                    onNotify("ブラウザがクリップボードへのアクセスを許可していません");
                  }
                }}
              >
                <Copy size={14} aria-hidden="true" /> コピー
              </button>
            )}
          </div>
          {result ? (
            <>
              <div className="result-text">{result.text}</div>
              <div className="result-meta">
                <span><span className="source-dot" /> {result.provider}</span>
                {result.notice && <span>{result.notice}</span>}
              </div>
            </>
          ) : (
            <div className="result-placeholder">
              <Bot size={22} aria-hidden="true" />
              <p>結果はこの場所に表示され、元データは変更されません。</p>
            </div>
          )}
        </section>
      </div>
    </div>
  );
}
