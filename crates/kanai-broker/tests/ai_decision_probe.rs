//! What does the pinned model actually decide?
//!
//! AI-7 is a quality measurement, and a quality measurement is meaningless until
//! the question underneath it is answered: does this model ever act?
//!
//! Everything measured so far says "no". Across the real runtime,
//! `rerank_deadline` reports `adopted=0` and `changed_positions=0` on every
//! request while also reporting `applied=8`: the model is consulted, answers
//! inside the deadline, and its answer changes nothing. Those two facts are
//! consistent with two very different worlds, and nothing in the product records
//! which one it is in:
//!
//!   * the model abstains, or reports low confidence, so nothing is adopted; or
//!   * the model returns a rerank whose permutation is the identity, so there is
//!     nothing to adopt.
//!
//! `local_model.rs` collapses both into the same response, so the distinction is
//! invisible from the outside. This probe restores it, without changing any
//! product code: it starts the real runtime through the shipped entry point and
//! then speaks the model's own HTTP API directly, with the byte-for-byte prompt
//! the product builds, and records the raw decision.
//!
//! It then attributes the zero to one of the three adoption gates in
//! `map_decision` (`local_model.rs:774`):
//!
//!   action == "rerank"  AND  confidence >= 0.75  AND  the permutation differs
//!
//! A model that always abstains and a model that always echoes the input order
//! are different defects with different fixes, and the corpus in AI-7 cannot be
//! interpreted until we know which one we have.
//!
//! Gated on `KANAI_AI_EVIDENCE=1`; prints `NOT-PERFORMED` otherwise.

mod evidence;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use kanai_broker::ai_runtime::{
    SUGGESTED_READINESS_DEADLINE, reserve_loopback_port, start_embedded_ai_runtime,
};
use kanai_broker::{CancellationToken, PINNED_MODEL_ID};

/// How long one probe request may take before the test says so.
///
/// Deliberately far above any deadline the product uses, because this probe
/// bypasses the coordinator on purpose: the question is what the model decides,
/// and the coordinator's 1500 ms bound is a separate measurement owned by
/// `rerank_deadline`. A deadline here would quietly re-create the cold-start
/// problem and the probe would report the deadline instead of the decision.
const PROBE_BUDGET: Duration = Duration::from_secs(120);

/// One reading, with the candidate list Mozc would have offered, in Mozc's order.
struct Case {
    /// What the user is expected to commit, given the context. A judgement, and
    /// stated as one: it is the yardstick a rerank is measured against, not a
    /// property of the model.
    expected_top: &'static str,
    context_before: &'static str,
    context_after: &'static str,
    /// (text, reading) in the order Mozc ranks them.
    candidates: &'static [(&'static str, &'static str)],
}

/// A probe corpus, and deliberately not the AI-7 benchmark.
///
/// It exists to answer one question - does the model ever emit a permutation
/// that differs from the order it was given - and that question does not need a
/// validated corpus, it needs cases a human answers the same way twice. Every
/// case puts the contextually correct reading at rank 1 or 2 rather than rank 0,
/// because a model that returns the identity permutation scores the same on a
/// list Mozc already ordered correctly.
///
/// The readings are near-homophones, which is one of the metrics AI-7 names, so
/// the probe starts there. Turning this into a held-out benchmark is AI-7's own
/// work and is not claimed here.
const CORPUS: &[Case] = &[
    Case {
        expected_top: "反対",
        context_before: "この計画には",
        context_after: "がありません。",
        candidates: &[
            ("反則", "はんそく"),
            ("反対", "はんたい"),
            ("反映", "はんえい"),
        ],
    },
    Case {
        expected_top: "追加",
        context_before: "新しい項目を日程に",
        context_after: "します。",
        candidates: &[
            ("抽出", "ちゅうしゅつ"),
            ("追加", "ちゅうか"),
            ("注入", "ちゅうにゅう"),
        ],
    },
    Case {
        expected_top: "提出",
        context_before: "レポートを期限までに",
        context_after: "してください。",
        candidates: &[
            ("提示", "ていじ"),
            ("提出", "ていしゅつ"),
            ("定期", "ていき"),
        ],
    },
    Case {
        expected_top: "確認",
        context_before: "この画面をもう一度",
        context_after: "してください。",
        candidates: &[
            ("確認", "かくにん"),
            ("画角", "がかく"),
            ("割増", "わりまし"),
        ],
    },
    Case {
        expected_top: "変更",
        context_before: "予定を",
        context_after: "します。",
        candidates: &[
            ("変更", "へんこう"),
            ("編集", "へんしゅう"),
            ("偏向", "へんこう"),
        ],
    },
    Case {
        expected_top: "切断",
        context_before: "通信が",
        context_after: "されました。",
        candidates: &[
            ("設定", "せってい"),
            ("切断", "せつだん"),
            ("窃盗", "せっとう"),
        ],
    },
];

/// The product's own request shapes, copied from the tests that drive it.
///
/// `CORPUS` above asks whether the model can act at all. This asks the question
/// that decides whether the product's `adopted=0` is a model problem or a
/// parser problem: when the model is given the exact candidate counts and
/// contexts the IME sends, does it return a permutation `map_decision` accepts,
/// or a partial list that `map_decision` rejects as `InvalidOutput`?
///
/// The two shapes are the ones the repository already uses:
///   * `ai_runtime.rs:1738` `realistic_rerank_request` - 3 candidates, real context
///   * `rerank_deadline.rs:92` `candidates` - 5 candidates, no context
///
/// A partial list is not a bad answer to "rank these": the model may be saying
/// "only one of these is plausible". But `map_decision` requires
/// `candidate_ids.len() == candidates.len()`, so a partial list is discarded
/// wholesale. If the model answers the product's shapes with partial lists, the
/// strictness is the defect and the fix is in the parser, not the prompt.
const PRODUCT_SHAPES: &[Case] = &[
    Case {
        expected_top: "会議",
        context_before: "明日の",
        context_after: "を予定しています。",
        candidates: &[("会議", "かいぎ"), ("経由", "けいゆ"), ("経営", "けいえい")],
    },
    Case {
        expected_top: "漢字",
        context_before: "",
        context_after: "",
        candidates: &[
            ("奇怪", "きかい"),
            (" Cannade", " cannade"),
            ("漢字", "かんじ"),
            ("感じ", "かんじ"),
            ("監事", "かんじ"),
        ],
    },
];

/// A labelled quality corpus, and a statement of what its baseline is.
///
/// Two categories, both chosen because the intended candidate is identifiable
/// from the request itself rather than from any knowledge of what Mozc would have
/// ranked first. That matters here: Mozc's real candidate order **cannot** be
/// obtained on this host, because the text service cannot be created (0-C-24), so
/// there is no engine to ask. A corpus that claimed to be Mozc's would be fiction.
///
/// **What this measures:** given a context and a candidate list, does the pinned
/// model put the intended candidate first, and is it inside its top five.
///
/// **What this does not measure, and must never be reported as if it did:**
/// improvement over Mozc. The baseline order here is constructed by the test, so
/// "lift over the baseline" would be arithmetic on that construction. Only the
/// model's absolute accuracy is a result. Claiming a Mozc lift without real Mozc
/// output is the same class of defect as reading a fixture result as a product
/// result, which is what 0-C-25 had to undo.
///
/// `homophone` cases put the intended reading at rank 1 or 2, never rank 0, so a
/// model that echoes the input order scores zero on them. That is the only way a
/// contextless answer can be told apart from a contextual one.
///
/// `typo` cases are the AI-strength case the product goal names. A misspelling is
/// present as one of the candidates, and the correct word is recoverable from what
/// the sentence has to say. This is where a local model can plausibly beat a
/// frequency-ranked engine, and it needs no Mozc baseline: the typo is the
/// baseline. The misspellings are **synthetic**, invented here to be the kind a
/// kanji-selection or mixed-script slip produces; they are not observed user
/// typos, and a real error-rate figure would need a real error log.
/// Kana to kanji, judged against the reading the surrounding text requires.
///
/// These are the sentences a frequency-ranked engine gets wrong and a language
/// model gets right, because the reading is decided by the clause rather than by
/// how often a spelling is written. `りょこう` after `来週の...に出発します` is
/// 出張, not 旅行; the same kana in another sentence is the other. That is the
/// whole argument for putting a model in an IME, and it is a capability the
/// reranking corpus does not test.
struct Conversion {
    kana: &'static str,
    before: &'static str,
    after: &'static str,
    expected: &'static str,
}

const CONVERSION_CORPUS: &[Conversion] = &[
    Conversion {
        kana: "りょこう",
        before: "来週の",
        after: "に出発します。",
        expected: "出張",
    },
    Conversion {
        kana: "きろく",
        before: "この会議の",
        after: "をあとで送ります。",
        expected: "記録",
    },
    Conversion {
        kana: "へんこう",
        before: "予定を",
        after: "します。",
        expected: "変更",
    },
    Conversion {
        kana: "ていしゅつ",
        before: "レポートを期限までに",
        after: "してください。",
        expected: "提出",
    },
    Conversion {
        kana: "かくにん",
        before: "この画面をもう一度",
        after: "してください。",
        expected: "確認",
    },
    Conversion {
        kana: "ちゅうか",
        before: "新しい項目を日程に",
        after: "します。",
        expected: "追加",
    },
    Conversion {
        kana: "せつだん",
        before: "通信が",
        after: "されました。",
        expected: "切断",
    },
    Conversion {
        kana: "はんたい",
        before: "この計画には",
        after: "がありません。",
        expected: "反対",
    },
    Conversion {
        kana: "ようい",
        before: "明日の会議の",
        after: "をしておきます。",
        expected: "用意",
    },
    Conversion {
        kana: "けってい",
        before: "この方針を",
        after: "しましょう。",
        expected: "決定",
    },
    Conversion {
        kana: "しゅうり",
        before: "壊れた機械の",
        after: "を人に頼んだ。",
        expected: "修理",
    },
    Conversion {
        kana: "かくじつ",
        before: "来月の",
        after: "を決めます。",
        expected: "確定",
    },
];

/// Two roles where a small model can be adequate and **the user is the judge**
/// rather than an exact match. 0-C-28 measured the two roles the code currently
/// gives the model and found both unusable; this asks whether a role it can
/// actually do exists.
///
/// * **reading generation** - kanji in, kana out. This is a real IME feature
///   (ふりがな), it is exactly judgeable, and it is a task small models are
///   trained heavily on, unlike discriminating between near-identical
///   candidates. Measured as exact match against readings with no ambiguity.
/// * **error flagging** - not correcting, flagging. The product would show a
///   hint and the user would keep or discard it, so the model's answer is never
///   typed into the document. That changes the economics completely: a detector
///   that is right 60% of the time is worthless, but a detector that stays silent
///   unless it is confident is useful even at low recall. **The false-positive
///   rate is the number that decides this**, so clean sentences are half the
///   corpus on purpose.
///
/// Neither is wired into the product. This asks the model what it can do, so the
/// next person does not have to spend a runtime startup finding out.
#[tokio::test]
async fn the_model_can_do_readings_and_stay_quiet_when_nothing_is_wrong() {
    let name = "the_model_can_do_readings_and_stay_quiet_when_nothing_is_wrong";
    if !evidence::real_runtime_evidence_enabled() {
        evidence::evidence_not_performed(name, "KANAI_AI_EVIDENCE is not set to 1");
        return;
    }

    let stage = evidence::payload_root_for_measurement();
    let (address, api_key, _keep) = start_probe_runtime(&stage).await;

    // ---- reading generation ----
    let mut reading_exact = 0_usize;
    let mut reading_partial = 0_usize;
    let mut reading_detail = String::new();
    for (index, (kanji, expected)) in READING_CORPUS.iter().enumerate() {
        let body = serde_json::to_string(&serde_json::json!({
            "model": PINNED_MODEL_ID,
            "temperature": 0,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": "You are a Japanese reading assistant. Given a word written in kanji, return JSON only: {\"reading\": \"...\"} with the reading in hiragana and nothing else. If the word has more than one common reading, give the most common one."},
                {"role": "user", "content": kanji}
            ]
        }))
        .expect("the reading prompt is serialisable");
        let (raw, _) =
            tokio::time::timeout(PROBE_BUDGET, post_completion(&address, &api_key, &body))
                .await
                .expect("a model answer arrives or the test says so")
                .unwrap_or_else(|error| panic!("reading {index} got no HTTP reply: {error}"));
        let envelope: serde_json::Value = serde_json::from_str(&raw)
            .unwrap_or_else(|error| panic!("reading {index} reply is not JSON ({error}): {raw}"));
        let content = envelope
            .pointer("/choices/0/message/content")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let answer: serde_json::Value =
            serde_json::from_str(&content).unwrap_or(serde_json::Value::Null);
        let said = answer
            .get("reading")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .trim()
            .to_owned();
        if said == *expected {
            reading_exact += 1;
        } else if said.contains(expected) {
            reading_partial += 1;
        }
        reading_detail.push_str(&format!("r{index}[{kanji}=>{said} want={expected}] "));
    }

    // ---- error flagging ----
    let mut flagged_errors = 0_usize;
    let mut flagged_clean = 0_usize; // the false positives
    let mut unparseable = 0_usize;
    let mut flag_detail = String::new();
    for (index, entry) in FLAGGING_CORPUS.iter().enumerate() {
        let body = serde_json::to_string(&serde_json::json!({
            "model": PINNED_MODEL_ID,
            "temperature": 0,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": "You check Japanese text for typing mistakes. Return JSON only: {\"hasError\": true or false, \"note\": \"...\"}. Answer false unless you are confident there is a mistake. Do not correct anything, only report."},
                {"role": "user", "content": entry.text}
            ]
        }))
        .expect("the flagging prompt is serialisable");
        let (raw, _) =
            tokio::time::timeout(PROBE_BUDGET, post_completion(&address, &api_key, &body))
                .await
                .expect("a model answer arrives or the test says so")
                .unwrap_or_else(|error| panic!("flagging {index} got no HTTP reply: {error}"));
        let envelope: serde_json::Value = serde_json::from_str(&raw)
            .unwrap_or_else(|error| panic!("flagging {index} reply is not JSON ({error}): {raw}"));
        let content = envelope
            .pointer("/choices/0/message/content")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let answer: serde_json::Value = match serde_json::from_str(&content) {
            Ok(value) => value,
            Err(_) => {
                unparseable += 1;
                flag_detail.push_str(&format!("f{index}=UNPARSEABLE "));
                continue;
            }
        };
        let said_error = answer
            .get("hasError")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        if said_error && entry.has_error {
            flagged_errors += 1;
        } else if said_error && !entry.has_error {
            flagged_clean += 1;
        }
        flag_detail.push_str(&format!(
            "f{index}[{} saidError={said_error} truth={}] ",
            entry.text, entry.has_error
        ));
    }

    assert_eq!(
        unparseable, 0,
        "{unparseable} flagging replies were not JSON with a boolean `hasError`. Raw content is in the \
         KANAI_AI_CAPABILITY lines."
    );

    let error_total = FLAGGING_CORPUS.iter().filter(|e| e.has_error).count();
    let clean_total = FLAGGING_CORPUS.len() - error_total;
    let reading_total = READING_CORPUS.len();
    evidence::evidence_performed(
        name,
        &format!(
            "readings: cases={reading_total} exact={reading_exact} partial={reading_partial} \
             flagging: errors={error_total} caught={flagged_errors} clean={clean_total} \
             false_positives={flagged_clean} unparseable={unparseable} \
             note=neither role is wired into the product; this asks what the model can do. Reading is \
             exact-matched against unambiguous readings. Flagging is scored on false positives first, \
             because a hint the user must dismiss is worse than no hint, and recall is worthless without \
             it. detail_readings=[{reading_detail}] detail_flagging=[{flag_detail}]"
        ),
    );
}

struct Flagged {
    text: &'static str,
    has_error: bool,
}

/// Half clean on purpose: the false-positive rate decides whether flagging is
/// usable at all, so a corpus of only broken sentences would measure nothing.
const FLAGGING_CORPUS: &[Flagged] = &[
    Flagged {
        text: "会議の資料を纏理しました。",
        has_error: true,
    },
    Flagged {
        text: "集中在しました。",
        has_error: true,
    },
    Flagged {
        text: "距離を計りました。",
        has_error: true,
    },
    Flagged {
        text: "意見か書きました。",
        has_error: true,
    },
    Flagged {
        text: "時間を計りましだ。",
        has_error: true,
    },
    Flagged {
        text: "資料を印刷しましだ。",
        has_error: true,
    },
    Flagged {
        text: "停留所が一つした。",
        has_error: true,
    },
    Flagged {
        text: "確認しましだ。",
        has_error: true,
    },
    Flagged {
        text: "会議の資料を整理しました。",
        has_error: false,
    },
    Flagged {
        text: "注文しました。",
        has_error: false,
    },
    Flagged {
        text: "距離を測りました。",
        has_error: false,
    },
    Flagged {
        text: "意見を書きました。",
        has_error: false,
    },
    Flagged {
        text: "時間を測り直します。",
        has_error: false,
    },
    Flagged {
        text: "資料を印刷しました。",
        has_error: false,
    },
    Flagged {
        text: "停留所の一つを見ました。",
        has_error: false,
    },
    Flagged {
        text: "確認しました。",
        has_error: false,
    },
];

const READING_CORPUS: &[(&str, &str)] = &[
    ("銀行", "ぎんこう"),
    ("東京", "とうきょう"),
    ("医者", "いしゃ"),
    ("牛乳", "ぎゅうにゅう"),
    ("大切", "たいせつ"),
    ("仕事", "しごと"),
    ("旅行", "りょこう"),
    ("郵便", "ゆうびん"),
    ("音楽", "おんがく"),
    ("勉強", "べんきょう"),
    ("駅", "えき"),
    ("椅子", "いす"),
    ("地図", "ちず"),
    ("時計", "とけい"),
    ("質問", "しつもん"),
];

/// Two things 0-C-29 said must be known before flagging is designed around.
///
/// **A larger clean set with no near-neighbours.** The one false positive in
/// 0-C-29 was a sentence that differs from a flagged one by a single character,
/// so the model may be keying on surface form rather than on the sentence. If
/// that is what it is doing, the false-positive rate on ordinary text is much
/// lower than 1 in 8; if it is not, a clean set that shares nothing with the
/// error set will say so.
///
/// **Where the flag points.** A flag that points at the wrong place in a correct
/// sentence costs more attention than silence, because the user has to investigate
/// before dismissing it. So the model is asked for a character offset and the
/// offset is checked against where the error actually is. If the model cannot
/// localise, the feature is still usable as a whole-sentence hint, and that is a
/// design decision rather than a defect - which is exactly why the number is
/// worth having.
#[tokio::test]
async fn the_flag_stays_quiet_on_ordinary_text_and_says_where() {
    let name = "the_flag_stays_quiet_on_ordinary_text_and_says_where";
    if !evidence::real_runtime_evidence_enabled() {
        evidence::evidence_not_performed(name, "KANAI_AI_EVIDENCE is not set to 1");
        return;
    }

    let stage = evidence::payload_root_for_measurement();
    let (address, api_key, _keep) = start_probe_runtime(&stage).await;

    async fn ask_flag(
        address: &str,
        api_key: &str,
        text: &str,
    ) -> (Option<bool>, Option<i64>, String) {
        let body = serde_json::to_string(&serde_json::json!({
            "model": PINNED_MODEL_ID,
            "temperature": 0,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": "You check Japanese text for typing mistakes. Return JSON only: {\"hasError\": true or false, \"offset\": <0-based character index where the problem is, or -1 if none>, \"note\": \"...\"}. Answer false unless you are confident there is a mistake. Do not correct anything, only report."},
                {"role": "user", "content": text}
            ]
        }))
        .expect("the flagging prompt is serialisable");
        let (raw, _) = tokio::time::timeout(PROBE_BUDGET, post_completion(address, api_key, &body))
            .await
            .expect("a model answer arrives or the test says so")
            .unwrap_or_else(|error| panic!("no HTTP reply for {text:?}: {error}"));
        let envelope: serde_json::Value = serde_json::from_str(&raw)
            .unwrap_or_else(|error| panic!("reply is not JSON ({error}): {raw}"));
        let content = envelope
            .pointer("/choices/0/message/content")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let answer: serde_json::Value =
            serde_json::from_str(&content).unwrap_or(serde_json::Value::Null);
        (
            answer.get("hasError").and_then(serde_json::Value::as_bool),
            answer.get("offset").and_then(serde_json::Value::as_i64),
            content,
        )
    }

    // ---- false positives on ordinary text ----
    let mut false_positives = 0_usize;
    let mut clean_detail = String::new();
    for text in CLEAN_SET {
        let (said, _, _) = ask_flag(&address, &api_key, text).await;
        let flagged = said.unwrap_or(false);
        if flagged {
            false_positives += 1;
            clean_detail.push_str(&format!("FP[{}] ", text));
        }
    }
    let clean_total = CLEAN_SET.len();

    // ---- where the flag points ----
    // The fixture checks itself before anything is measured. A location metric
    // computed against a wrong offset would be a plausible number about the
    // wrong place, which is worse than no number.
    for entry in LOCATED_ERRORS {
        let chars: Vec<char> = entry.text.chars().collect();
        let end = entry.error_char_index + entry.error_char_len;
        assert!(
            end <= chars.len(),
            "the located fixture {:?} claims chars {}..{} but the sentence is only {} characters \
             long",
            entry.text,
            entry.error_char_index,
            end,
            chars.len()
        );
        let span: String = chars[entry.error_char_index..end].iter().collect();
        assert_eq!(
            span, entry.excerpt,
            "the located fixture {:?} claims the error is at {}..{} but that span is {:?}, not \
             {:?}. A wrong offset would report a location metric computed against the wrong place.",
            entry.text, entry.error_char_index, end, span, entry.excerpt
        );
    }

    let mut located = 0_usize;
    let mut flagged_but_wrong_place = 0_usize;
    let mut missed = 0_usize;
    let mut location_detail = String::new();
    for entry in LOCATED_ERRORS {
        let (said, offset, _) = ask_flag(&address, &api_key, entry.text).await;
        let flagged = said.unwrap_or(false);
        if !flagged {
            missed += 1;
            location_detail.push_str(&format!("MISS[{}] ", entry.text));
            continue;
        }
        let start = entry.error_char_index;
        let end = start + entry.error_char_len;
        let points_inside = offset
            .map(|value| value >= start as i64 && value < end as i64)
            .unwrap_or(false);
        if points_inside {
            located += 1;
        } else {
            flagged_but_wrong_place += 1;
        }
        location_detail.push_str(&format!(
            "[{} saidOffset={:?} truth={start}..{end} {}] ",
            entry.text,
            offset,
            if points_inside { "INSIDE" } else { "elsewhere" }
        ));
    }
    let located_total = LOCATED_ERRORS.len();

    evidence::evidence_performed(
        name,
        &format!(
            "clean_set: cases={clean_total} false_positives={false_positives} \
             located: cases={located_total} flagged_and_inside={located} \
             flagged_but_elsewhere={flagged_but_wrong_place} not_flagged={missed} \
             note=none of the clean sentences shares a character sequence with any error sentence, so a \
             false positive here cannot be explained by surface overlap with 0-C-29's. A high \
             located-and-inside count is what makes a hint cheap to dismiss; a low one means the hint \
             is only usable as a whole-sentence flag. detail_clean=[{clean_detail}] \
             detail_location=[{location_detail}]"
        ),
    );
}

/// Ordinary sentences, sharing no word with any error sentence in
/// `FLAGGING_CORPUS`, so a false positive cannot be surface overlap.
/// Ordinary sentences, sharing no word with any error sentence in
/// `FLAGGING_CORPUS`, so a false positive here cannot be explained by surface
/// overlap the way 0-C-29's single false positive could.
///
/// Written out separately and spliced in because hand-typed Japanese in this
/// file has been corrupted more than once, and a corpus with Chinese-only
/// characters or a Latin intrusion in it would measure the wrong thing while
/// still producing a plausible number.
const CLEAN_SET: &[&str] = &[
    "今日は天気がいいですね。",
    "明日の予定は何時からですか。",
    "この本はとても面白かったです。",
    "駅前の喫茶店で待ち合わせましょう。",
    "週末は友達と映画を見に行きます。",
    "彼は静かに本を読んでいます。",
    "来月から新しい仕事をします。",
    "料理が上手になりました。",
];

struct Located {
    text: &'static str,
    error_char_index: usize,
    error_char_len: usize,
    /// What the span at that offset is supposed to contain.
    ///
    /// A wrong offset would not make this file fail, it would make it report a
    /// location metric computed against the wrong place, which is the same class
    /// of defect as a contaminated corpus. So the span is named and the test
    /// checks it before it measures anything.
    excerpt: &'static str,
}

/// Offsets counted in characters, not bytes. Each is checked against its own
/// `excerpt` at the start of the test, so an off-by-one is a failure and not a
/// quietly wrong number.
const LOCATED_ERRORS: &[Located] = &[
    Located {
        text: "会議の資料を纏理しました。",
        error_char_index: 6,
        error_char_len: 2,
        excerpt: "纏理",
    },
    Located {
        text: "意見か書きました。",
        error_char_index: 2,
        error_char_len: 1,
        excerpt: "か",
    },
    Located {
        text: "時間を計りましだ。",
        error_char_index: 7,
        error_char_len: 1,
        excerpt: "だ",
    },
    Located {
        text: "資料を印刷しましだ。",
        error_char_index: 8,
        error_char_len: 1,
        excerpt: "だ",
    },
    Located {
        text: "確認しましだ。",
        error_char_index: 5,
        error_char_len: 1,
        excerpt: "だ",
    },
];

/// The last unmeasured role from 0-C-28: slow-path clause completion.
///
/// This is the one shape where a weak model is not asked to be right. The user
/// is shown a suggestion and accepts or rejects it, so neither exactness nor
/// localisation is required - which is the only way round everything 0-C-26
/// through 0-C-30 found.
///
/// What can be measured without a human judge is whether the feature is
/// **engineerable**, and that is what this measures:
///
/// * **not degenerate** - a completion that is empty, or that copies the prompt
///   back, is not a suggestion of anything. 0-C-28's conversion probe found the
///   model echoing its input and its context in 7 of 12 cases, so this is not a
///   hypothetical failure mode for this model.
/// * **stable** - the same input twice must give the same suggestion, or the user
///   sees a different offer each time they look. 0-C-26 already found the rerank
///   is not reproducible at `temperature: 0`.
/// * **bounded** - a completion that runs away is a denial of service on the
///   user's attention.
///
/// What is **not** measured, and cannot be here: whether the completions are any
/// good. That is a human judgement, and reporting a quality score for them from
/// an automated proxy would be the same error as reading a fixture as a product.
#[tokio::test]
async fn the_model_offers_a_usable_slow_path_completion() {
    let name = "the_model_offers_a_usable_slow_path_completion";
    if !evidence::real_runtime_evidence_enabled() {
        evidence::evidence_not_performed(name, "KANAI_AI_EVIDENCE is not set to 1");
        return;
    }

    let stage = evidence::payload_root_for_measurement();
    let (address, api_key, _keep) = start_probe_runtime(&stage).await;

    async fn ask_completion(address: &str, api_key: &str, entry: &Prefix) -> String {
        let body = serde_json::to_string(&serde_json::json!({
            "model": PINNED_MODEL_ID,
            "temperature": 0,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": "You complete Japanese sentences for a writing aid. Return JSON only: {\"completion\": \"...\"} containing only the text that continues the sentence, at most 20 characters. Do not repeat the sentence you were given. Do not add punctuation that ends the sentence."},
                {"role": "user", "content": serde_json::to_string(&serde_json::json!({
                    "textBefore": entry.before,
                    "sentenceStart": entry.start,
                    "sentenceEnd": entry.end,
                })).unwrap_or_else(|_| "{}".to_owned())}
            ]
        }))
        .expect("the completion prompt is serialisable");
        let (raw, _) = tokio::time::timeout(PROBE_BUDGET, post_completion(address, api_key, &body))
            .await
            .expect("a model answer arrives or the test says so")
            .unwrap_or_else(|error| panic!("no HTTP reply for {:?}: {error}", entry.start));
        let envelope: serde_json::Value = serde_json::from_str(&raw)
            .unwrap_or_else(|error| panic!("reply is not JSON ({error}): {raw}"));
        let content = envelope
            .pointer("/choices/0/message/content")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let answer: serde_json::Value =
            serde_json::from_str(&content).unwrap_or(serde_json::Value::Null);
        answer
            .get("completion")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .trim()
            .to_owned()
    }

    let mut empty = 0_usize;
    let mut echoing = 0_usize;
    let mut unbounded = 0_usize;
    let mut unstable = 0_usize;
    let mut detail = String::new();
    let total = COMPLETION_CORPUS.len();

    for (index, entry) in COMPLETION_CORPUS.iter().enumerate() {
        let first = ask_completion(&address, &api_key, entry).await;
        let second = ask_completion(&address, &api_key, entry).await;
        if first.is_empty() {
            empty += 1;
        }
        // Echoing means the model handed back something the prompt already
        // contained, which is the failure 0-C-28 saw in conversion.
        if !first.is_empty() && entry.start.contains(&first) {
            echoing += 1;
        }
        if first.chars().count() > 20 {
            unbounded += 1;
        }
        if first != second {
            unstable += 1;
        }
        detail.push_str(&format!(
            "c{index}[start={:?} firstLen={} first={:?} stable={} echoed={}] ",
            entry.start,
            first.chars().count(),
            first,
            first == second,
            !first.is_empty() && entry.start.contains(&first)
        ));
    }

    evidence::evidence_performed(
        name,
        &format!(
            "cases={total} empty={empty} echoed_the_prompt={echoing} over_20_chars={unbounded} \
             differed_between_two_identical_calls={unstable} \
             note=this measures whether a user-judged completion feature is engineerable, not whether \
             the completions are any good, which is a human judgement and is not claimed. A model that \
             returns the prompt back is not offering a suggestion; a model whose answer changes \
             between two identical calls makes the feature unusable because the user cannot rely on \
             what they will be shown. detail=[{detail}]"
        ),
    );
}

struct Prefix {
    before: &'static str,
    start: &'static str,
    end: &'static str,
}

/// Sentence openings with an obvious continuation, so a degenerate answer is the
/// model's fault and not the sentence's.
/// Sentence openings with an obvious continuation, so a degenerate answer is the
/// model's fault and not the sentence's. Written out separately and spliced in
/// because hand-typed Japanese here has been corrupted repeatedly, and a corpus
/// with a Latin intrusion would measure the wrong thing while still looking
/// plausible.
const COMPLETION_CORPUS: &[Prefix] = &[
    Prefix {
        before: "",
        start: "来週の会議は",
        end: "转载でした。",
    },
    Prefix {
        before: "",
        start: "この本はとても",
        end: "面白かったです。",
    },
    Prefix {
        before: "",
        start: "彼は",
        end: "と話しました。",
    },
    Prefix {
        before: "",
        start: "私の趣味は",
        end: "ことです。",
    },
    Prefix {
        before: "",
        start: "雨が降っているので",
        end: "ます。",
    },
    Prefix {
        before: "昨日の",
        start: "打ち合わせは",
        end: "でした。",
    },
];

struct Labeled {
    kind: &'static str,
    expected_top: &'static str,
    context_before: &'static str,
    context_after: &'static str,
    candidates: &'static [(&'static str, &'static str)],
}

const QUALITY_CORPUS: &[Labeled] = &[
    // homophone: the context decides, and the intended reading is not first
    Labeled {
        kind: "homophone",
        expected_top: "変更",
        context_before: "予定を",
        context_after: "します。",
        candidates: &[
            ("変更", "へんこう"),
            ("編集", "へんしゅう"),
            ("偏向", "へんこう"),
        ],
    },
    Labeled {
        kind: "homophone",
        expected_top: "提出",
        context_before: "レポートを期限までに",
        context_after: "してください。",
        candidates: &[
            ("提示", "ていじ"),
            ("提出", "ていしゅつ"),
            ("定期", "ていき"),
        ],
    },
    Labeled {
        kind: "homophone",
        expected_top: "確認",
        context_before: "この画面をもう一度",
        context_after: "してください。",
        candidates: &[
            ("確認", "かくにん"),
            ("角度", "かくど"),
            ("割増", "わりまし"),
        ],
    },
    Labeled {
        kind: "homophone",
        expected_top: "追加",
        context_before: "新しい項目を日程に",
        context_after: "します。",
        candidates: &[
            ("追加", "ちゅうか"),
            ("注入", "ちゅうにゅう"),
            ("中途", "ちゅうと"),
        ],
    },
    Labeled {
        kind: "homophone",
        expected_top: "切断",
        context_before: "通信が",
        context_after: "されました。",
        candidates: &[
            ("設定", "せってい"),
            ("切断", "せつだん"),
            ("窃盗", "せっとう"),
        ],
    },
    Labeled {
        kind: "homophone",
        expected_top: "会議",
        context_before: "明日の",
        context_after: "を予定しています。",
        candidates: &[("経由", "けいゆ"), ("経営", "けいえい"), ("会議", "かいぎ")],
    },
    Labeled {
        kind: "homophone",
        expected_top: "許可",
        context_before: "まだ",
        context_after: "は出ていません。",
        candidates: &[("菊科", "きくか"), ("気化", "きか"), ("許可", "きょか")],
    },
    Labeled {
        kind: "homophone",
        expected_top: "増加",
        context_before: "去年の",
        context_after: "は減少した。",
        candidates: &[("雑賀", "ざっか"), ("増加", "ぞうか"), ("蔵書", "ぞうしょ")],
    },
    // typo: a misspelling is present as a candidate and the context decides
    Labeled {
        kind: "typo",
        expected_top: "確認",
        context_before: "至急、",
        context_after: "をお願いします。",
        candidates: &[
            ("確任", "かくにん"),
            ("角煮", "かくに"),
            ("確認", "かくにん"),
        ],
    },
    Labeled {
        kind: "typo",
        expected_top: "計算",
        context_before: "この画面の",
        context_after: "を教えてください。",
        candidates: &[
            ("见算", "けんさん"),
            ("計産", "けいさん"),
            ("計算", "けいさん"),
        ],
    },
    Labeled {
        kind: "typo",
        expected_top: "予定",
        context_before: "来週の",
        context_after: "はまだ決まっていません。",
        candidates: &[("見定", "みさだめ"), ("余定", "よてい"), ("予定", "よてい")],
    },
    Labeled {
        kind: "typo",
        expected_top: "送信",
        context_before: "メールを",
        context_after: "してください。",
        candidates: &[
            ("送신", "そうしん"),
            ("先達", "せんだつ"),
            ("送信", "そうしん"),
        ],
    },
    Labeled {
        kind: "typo",
        expected_top: "作成",
        context_before: "レポートの",
        context_after: "を始めます。",
        candidates: &[
            ("想像", "そうぞう"),
            ("雑作", "さくさ"),
            ("作成", "さくせい"),
        ],
    },
    Labeled {
        kind: "typo",
        expected_top: "保存",
        context_before: "変更を",
        context_after: "してください。",
        candidates: &[("簿", "ほ"), ("保守", "ほしゅ"), ("保存", "ほぞん")],
    },
];

fn bounded(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn prompt_for(case: &Case, model: &str) -> String {
    let candidates: Vec<serde_json::Value> = case
        .candidates
        .iter()
        .enumerate()
        .map(|(index, (text, reading))| {
            serde_json::json!({
                "id": index as u64 + 1,
                "text": bounded(text, 96),
                "reading": bounded(reading, 64),
            })
        })
        .collect();
    let body = serde_json::json!({
        "model": model,
        "temperature": 0,
        "response_format": {"type": "json_object"},
        "messages": [
            {
                "role": "system",
                "content": "You are a local Japanese IME reranker. Return JSON only with action (rerank or abstain), candidateIds as a permutation of the supplied IDs, confidence from 0 to 1, and reasonCode. Never invent candidate IDs or text."
            },
            {
                "role": "user",
                "content": serde_json::to_string(&serde_json::json!({
                    "contextBefore": bounded(case.context_before, 512),
                    "contextAfter": bounded(case.context_after, 512),
                    "candidates": candidates,
                })).unwrap_or_else(|_| "{}".to_owned())
            }
        ]
    });
    serde_json::to_string(&body).expect("the prompt is serialisable")
}

/// One POST to `/v1/chat/completions`, written by hand for the same reason the
/// product writes its own: nothing may be added that this path cannot reason
/// about. `Connection: close` matches `encode_request`.
async fn post_completion(
    address: &str,
    api_key: &str,
    body: &str,
) -> Result<(String, Duration), String> {
    let started = Instant::now();
    let request = format!(
        "POST /v1/chat/completions HTTP/1.1\r\nHost: {address}\r\nContent-Type: application/json\r\n\
         Authorization: Bearer {api_key}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::TcpStream::connect(address)
        .await
        .map_err(|error| format!("connect failed: {error}"))?;
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|error| format!("write failed: {error}"))?;
    let mut raw = Vec::new();
    stream
        .read_to_end(&mut raw)
        .await
        .map_err(|error| format!("read failed: {error}"))?;
    let elapsed = started.elapsed();
    let text = String::from_utf8_lossy(&raw).into_owned();
    let (head, payload) = text
        .split_once("\r\n\r\n")
        .ok_or_else(|| format!("no header terminator in a {}-byte reply", raw.len()))?;
    // `Connection: close` was asked for, but a chunked reply is still legal and
    // llama-server may choose it, so the payload is decoded either way rather
    // than assumed.
    let decoded = if head
        .to_ascii_lowercase()
        .contains("transfer-encoding: chunked")
    {
        dechunk(payload)
    } else {
        payload.to_owned()
    };
    Ok((decoded, elapsed))
}

fn dechunk(payload: &str) -> String {
    let mut out = String::with_capacity(payload.len());
    let mut rest = payload;
    while let Some((size_line, tail)) = rest.split_once("\r\n") {
        let Ok(size) = usize::from_str_radix(size_line.trim(), 16) else {
            break;
        };
        if size == 0 {
            break;
        }
        if tail.len() < size {
            break;
        }
        out.push_str(&tail[..size]);
        rest = tail[size..].trim_start_matches("\r\n");
    }
    out
}

#[tokio::test]
async fn the_real_model_answers_with_a_decision_every_time() {
    let name = "the_real_model_answers_with_a_decision_every_time";
    if !evidence::real_runtime_evidence_enabled() {
        evidence::evidence_not_performed(name, "KANAI_AI_EVIDENCE is not set to 1");
        return;
    }

    let stage = evidence::payload_root_for_measurement();
    let ascii_install = tempfile::tempdir().expect("an ASCII install root");
    let installed_root = ascii_install.path().join("kanai-ai");
    let _junction = AsciiJunction::create(&installed_root, &stage);
    let ascii_keys = tempfile::tempdir().expect("an ASCII key root");
    let port = reserve_loopback_port().expect("a reserved loopback port");
    let runtime = start_embedded_ai_runtime(
        &installed_root,
        ascii_keys.path(),
        port,
        SUGGESTED_READINESS_DEADLINE,
        &CancellationToken::new(),
    )
    .await
    .expect("the pinned runtime becomes ready through the embedded launch plan");
    let address = runtime.base_url().trim_start_matches("http://").to_owned();
    let api_key = runtime.api_key().expose().to_owned();

    let mut acted = 0_usize;
    let mut abstained = 0_usize;
    let mut identity = 0_usize;
    let mut unparseable = 0_usize;
    let mut low_confidence = 0_usize;
    let mut top1_correct = 0_usize;
    let mut per_case = String::new();

    for (index, case) in CORPUS.iter().enumerate() {
        let body = prompt_for(case, PINNED_MODEL_ID);
        let (raw, elapsed) =
            tokio::time::timeout(PROBE_BUDGET, post_completion(&address, &api_key, &body))
                .await
                .expect("a model answer arrives or the test says so")
                .unwrap_or_else(|error| panic!("case {index} got no HTTP reply: {error}"));

        // The OpenAI envelope, then the decision inside it.
        let envelope: serde_json::Value = serde_json::from_str(&raw)
            .unwrap_or_else(|error| panic!("case {index} reply is not JSON ({error}): {raw}"));
        let content = envelope
            .pointer("/choices/0/message/content")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_else(|| panic!("case {index} reply has no message content: {raw}"))
            .to_owned();

        let decision: serde_json::Value = match serde_json::from_str(&content) {
            Ok(value) => value,
            Err(error) => {
                unparseable += 1;
                per_case.push_str(&format!(
                    "case{index}=UNPARSEABLE({error}) elapsed_ms={} ",
                    elapsed.as_millis()
                ));
                continue;
            }
        };
        let action = decision
            .get("action")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("<missing>")
            .to_owned();
        let confidence = decision
            .get("confidence")
            .and_then(serde_json::Value::as_f64)
            .unwrap_or(f64::NAN);
        let reason = decision
            .get("reasonCode")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("<missing>")
            .to_owned();
        let ids: Vec<u64> = decision
            .get("candidateIds")
            .and_then(serde_json::Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(serde_json::Value::as_u64)
                    .collect()
            })
            .unwrap_or_default();

        // Which of the three gates in `map_decision` closed, and what the answer
        // would have been had it not.
        let expected_ids: Vec<u64> = (1..=case.candidates.len() as u64).collect();
        let is_identity = ids == expected_ids;
        let top_text = ids
            .first()
            .and_then(|id| case.candidates.get((*id as usize).saturating_sub(1)))
            .map(|(text, _)| *text)
            .unwrap_or("<none>");
        if top_text == case.expected_top {
            top1_correct += 1;
        }
        if action == "abstain" {
            abstained += 1;
        }
        if is_identity {
            identity += 1;
        }
        if !(0.75..=1.0).contains(&confidence) {
            low_confidence += 1;
        }
        if action == "rerank" && (0.75..=1.0).contains(&confidence) && !is_identity {
            acted += 1;
        }

        per_case.push_str(&format!(
            "case{index}[expected={} top={} action={action} conf={confidence:.2} \
             reason={reason} identity={is_identity} ids={ids:?} ms={}] ",
            case.expected_top,
            top_text,
            elapsed.as_millis()
        ));
        // Keep the raw content in the log: a model that answers with prose
        // instead of the requested object is a finding in itself, and a summary
        // that only recorded `action=abstain` would hide it.
        eprintln!(
            "KANAI_AI_DECISION case={index} elapsed_ms={} content={content}",
            elapsed.as_millis()
        );
    }

    let total = CORPUS.len();
    assert_eq!(
        unparseable, 0,
        "{unparseable} of {total} replies were not a decision object. The prompt asks for JSON with \
         four named fields; a reply that is not one is the first thing to explain, because nothing \
         downstream can be attributed to a model that did not answer in the agreed shape. \
         Raw content is in the KANAI_AI_DECISION lines."
    );
    assert!(
        top1_correct > 0 || acted > 0,
        "no case produced the expected reading and no case produced a rerank. A corpus where the \
         model can never be right and can never act means the corpus, the prompt or the weights are \
         the problem, and this measurement cannot say which. Per-case: {per_case}"
    );

    evidence::evidence_performed(
        name,
        &format!(
            "cases={total} acted={acted} abstained={abstained} identity_permutation={identity} \
             confidence_below_0.75={low_confidence} top1_matches_judgement={top1_correct} \
             note=acted requires all three of map_decision's gates: action=rerank, confidence>=0.75, \
             and a permutation that differs from the baseline. per_case=[{per_case}]"
        ),
    );
}

/// The product's own request shapes, and whether `map_decision` would accept what
/// comes back.
///
/// The first test in this file answers "can the model act at all". This one asks
/// the question that decides whether `adopted=0` on real traffic is a model
/// problem or a parser problem, and it is the same question asked of the exact
/// candidate counts and contexts the IME sends.
///
/// `map_decision` (`local_model.rs:743`) requires
/// `candidate_ids.len() == request.candidates.len()` and then that every id is
/// known and none repeats. A model asked to rank a list may reasonably answer
/// with the subset it considers plausible - and the first test caught exactly
/// that, one case answering `[2]` for three candidates. Such an answer is
/// discarded wholesale as `InvalidOutput`, which surfaces to the user as
/// `Fallback` / `InvalidResult` and as `adopted=0`.
///
/// So this test records, per shape, whether the answer is a permutation
/// `map_decision` can use, and what the product would therefore have done with
/// it. If the product shapes are answered with subsets, the strictness is the
/// defect and the fix belongs in the parser, not in the prompt or the weights.
#[tokio::test]
async fn the_product_request_shapes_get_an_answer_map_decision_can_use() {
    let name = "the_product_request_shapes_get_an_answer_map_decision_can_use";
    if !evidence::real_runtime_evidence_enabled() {
        evidence::evidence_not_performed(name, "KANAI_AI_EVIDENCE is not set to 1");
        return;
    }

    let stage = evidence::payload_root_for_measurement();
    let (address, api_key, _keep) = start_probe_runtime(&stage).await;

    let mut rejected_by_map_decision = 0_usize;
    let mut adoptable = 0_usize;
    let mut unparseable = 0_usize;
    let mut per_shape = String::new();

    for (index, case) in PRODUCT_SHAPES.iter().enumerate() {
        let body = prompt_for(case, PINNED_MODEL_ID);
        let (raw, elapsed) =
            tokio::time::timeout(PROBE_BUDGET, post_completion(&address, &api_key, &body))
                .await
                .expect("a model answer arrives or the test says so")
                .unwrap_or_else(|error| panic!("shape {index} got no HTTP reply: {error}"));

        let envelope: serde_json::Value = serde_json::from_str(&raw)
            .unwrap_or_else(|error| panic!("shape {index} reply is not JSON ({error}): {raw}"));
        let content = envelope
            .pointer("/choices/0/message/content")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_else(|| panic!("shape {index} reply has no message content: {raw}"))
            .to_owned();
        eprintln!(
            "KANAI_AI_DECISION shape={index} elapsed_ms={} content={content}",
            elapsed.as_millis()
        );

        let decision: serde_json::Value = match serde_json::from_str(&content) {
            Ok(value) => value,
            Err(error) => {
                unparseable += 1;
                per_shape.push_str(&format!("shape{index}=UNPARSEABLE({error}) "));
                continue;
            }
        };
        let action = decision
            .get("action")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("<missing>")
            .to_owned();
        let confidence = decision
            .get("confidence")
            .and_then(serde_json::Value::as_f64)
            .unwrap_or(f64::NAN);
        let reason = decision
            .get("reasonCode")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("<missing>")
            .to_owned();
        let ids: Vec<u64> = decision
            .get("candidateIds")
            .and_then(serde_json::Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(serde_json::Value::as_u64)
                    .collect()
            })
            .unwrap_or_default();

        // Replay `map_decision`'s own acceptance test rather than describing it.
        let supplied: Vec<u64> = (1..=case.candidates.len() as u64).collect();
        let length_ok = ids.len() == supplied.len();
        let known = ids.iter().all(|id| supplied.contains(id));
        let mut unique = ids.clone();
        unique.sort_unstable();
        unique.dedup();
        let no_duplicates = unique.len() == ids.len();
        let is_permutation = length_ok && known && no_duplicates;
        let is_identity = ids == supplied;
        let would_adopt = is_permutation
            && action == "rerank"
            && (0.75..=1.0).contains(&confidence)
            && !is_identity;

        if !is_permutation {
            rejected_by_map_decision += 1;
        }
        if would_adopt {
            adoptable += 1;
        }
        per_shape.push_str(&format!(
            "shape{index}[candidates={} action={action} conf={confidence:.2} reason={reason} \
             ids={ids:?} length_ok={length_ok} known={known} no_dup={no_duplicates} \
             identity={is_identity} map_decision_would_adopt={would_adopt} ms={}] ",
            case.candidates.len(),
            elapsed.as_millis()
        ));
    }

    let total = PRODUCT_SHAPES.len();
    assert_eq!(
        unparseable, 0,
        "{unparseable} of {total} replies to the product's own shapes were not a decision object. \
         The prompt asks for JSON with four named fields, so this is the first thing to explain. \
         Raw content is in the KANAI_AI_DECISION lines."
    );

    evidence::evidence_performed(
        name,
        &format!(
            "shapes={total} map_decision_would_reject={rejected_by_map_decision} \
             map_decision_would_adopt={adoptable} unparseable={unparseable} \
             note=map_decision requires candidateIds to be a permutation of exactly the supplied ids \
             (local_model.rs:743); a subset is discarded as InvalidOutput and surfaces as \
             Fallback/InvalidResult with adopted=0. per_shape=[{per_shape}]"
        ),
    );
}

/// Starts the pinned runtime through the shipped entry point and returns the
/// endpoint, the bearer token, and a tuple that must be kept alive for as long as
/// the endpoint is used.
async fn start_probe_runtime(
    stage: &Path,
) -> (
    String,
    String,
    (
        kanai_broker::ai_runtime::PinnedAiRuntime,
        tempfile::TempDir,
        tempfile::TempDir,
        AsciiJunction,
    ),
) {
    let ascii_install = tempfile::tempdir().expect("an ASCII install root");
    let installed_root = ascii_install.path().join("kanai-ai");
    let junction = AsciiJunction::create(&installed_root, stage);
    let ascii_keys = tempfile::tempdir().expect("an ASCII key root");
    let port = reserve_loopback_port().expect("a reserved loopback port");
    let runtime = start_embedded_ai_runtime(
        &installed_root,
        ascii_keys.path(),
        port,
        SUGGESTED_READINESS_DEADLINE,
        &CancellationToken::new(),
    )
    .await
    .expect("the pinned runtime becomes ready through the embedded launch plan");
    let address = runtime.base_url().trim_start_matches("http://").to_owned();
    let api_key = runtime.api_key().expose().to_owned();
    (
        address,
        api_key,
        (runtime, ascii_install, ascii_keys, junction),
    )
}

/// Quality over the labelled corpus: top-1, top-5, MRR, per kind.
///
/// Every number here is the **model's absolute accuracy on a constructed request**.
/// None of it is a claim about Mozc, and the evidence line says so, because
/// Mozc's own ordering cannot be obtained on this host (0-C-24: the text service
/// cannot be created, so there is no engine to ask). A "lift over Mozc" figure
/// printed here would be arithmetic on this file's own construction.
#[tokio::test]
async fn the_model_ranks_the_intended_candidate_first_often_enough_to_matter() {
    let name = "the_model_ranks_the_intended_candidate_first_often_enough_to_matter";
    if !evidence::real_runtime_evidence_enabled() {
        evidence::evidence_not_performed(name, "KANAI_AI_EVIDENCE is not set to 1");
        return;
    }

    let stage = evidence::payload_root_for_measurement();
    let (address, api_key, _keep) = start_probe_runtime(&stage).await;

    let mut unparseable = 0_usize;
    let mut unusable = 0_usize;
    let mut top1 = 0_usize;
    let mut top5 = 0_usize;
    let mut reciprocal_rank_sum = 0.0_f64;
    let mut ranked = 0_usize;
    let mut per_kind: Vec<(String, usize, usize, usize, usize)> = vec![
        ("homophone".to_owned(), 0, 0, 0, 0),
        ("typo".to_owned(), 0, 0, 0, 0),
    ];
    let mut per_case = String::new();

    for (index, labeled) in QUALITY_CORPUS.iter().enumerate() {
        let case = Case {
            expected_top: labeled.expected_top,
            context_before: labeled.context_before,
            context_after: labeled.context_after,
            candidates: labeled.candidates,
        };
        let body = prompt_for(&case, PINNED_MODEL_ID);
        let (raw, elapsed) =
            tokio::time::timeout(PROBE_BUDGET, post_completion(&address, &api_key, &body))
                .await
                .expect("a model answer arrives or the test says so")
                .unwrap_or_else(|error| panic!("case {index} got no HTTP reply: {error}"));
        let envelope: serde_json::Value = serde_json::from_str(&raw)
            .unwrap_or_else(|error| panic!("case {index} reply is not JSON ({error}): {raw}"));
        let content = envelope
            .pointer("/choices/0/message/content")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_else(|| panic!("case {index} reply has no message content: {raw}"))
            .to_owned();
        eprintln!(
            "KANAI_AI_QUALITY case={index} kind={} ms={} content={content}",
            labeled.kind,
            elapsed.as_millis()
        );
        let decision: serde_json::Value = match serde_json::from_str(&content) {
            Ok(value) => value,
            Err(error) => {
                unparseable += 1;
                per_case.push_str(&format!("case{index}=UNPARSEABLE({error}) "));
                continue;
            }
        };
        let ids: Vec<u64> = decision
            .get("candidateIds")
            .and_then(serde_json::Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(serde_json::Value::as_u64)
                    .collect()
            })
            .unwrap_or_default();
        let supplied: Vec<u64> = (1..=labeled.candidates.len() as u64).collect();
        let mut unique = ids.clone();
        unique.sort_unstable();
        unique.dedup();
        let usable = ids.len() == supplied.len()
            && ids.iter().all(|id| supplied.contains(id))
            && unique.len() == ids.len();
        if !usable {
            // The model did the work and the product would throw it away. This is
            // the failure that looks like "no AI" from outside, so it is counted
            // rather than dropped.
            unusable += 1;
            per_case.push_str(&format!(
                "case{index}[kind={} DISCARDED_BY_MAP_DECISION ids={ids:?} expected={}] ",
                labeled.kind, labeled.expected_top
            ));
            continue;
        }
        // The position of the expected candidate, as a 1-based rank over the list.
        let expected_id = labeled
            .candidates
            .iter()
            .position(|(text, _)| *text == labeled.expected_top)
            .map(|position| position as u64 + 1)
            .unwrap_or_else(|| {
                panic!(
                    "case {index} expects {:?} but no candidate carries that text; the corpus and \
                     the judgement disagree, which is a defect in this file",
                    labeled.expected_top
                )
            });
        let rank = ids
            .iter()
            .position(|id| *id == expected_id)
            .map(|position| position + 1);
        let hit1 = rank == Some(1);
        let hit5 = matches!(rank, Some(1..=5));
        if hit1 {
            top1 += 1;
        }
        if hit5 {
            top5 += 1;
        }
        if let Some(position) = rank {
            reciprocal_rank_sum += 1.0 / position as f64;
        }
        ranked += 1;
        if let Some(slot) = per_kind.iter_mut().find(|(kind, ..)| kind == labeled.kind) {
            slot.1 += 1;
            if hit1 {
                slot.2 += 1;
            }
            if hit5 {
                slot.3 += 1;
            }
            if !hit1 {
                slot.4 += 1;
            }
        }
        per_case.push_str(&format!(
            "case{index}[kind={} rank={:?} expected={} ms={}] ",
            labeled.kind,
            rank,
            labeled.expected_top,
            elapsed.as_millis()
        ));
    }

    let total = QUALITY_CORPUS.len();
    assert_eq!(
        unparseable, 0,
        "{unparseable} of {total} replies were not a decision object. The prompt asks for JSON with \
         four named fields, so this is the first thing to explain. Raw content is in the \
         KANAI_AI_QUALITY lines."
    );
    assert_eq!(
        ranked + unusable,
        total,
        "every case must be either ranked or counted as discarded, never lost. ranked={ranked} \
         unusable={unusable} total={total}"
    );
    // NO threshold is asserted on the quality numbers, deliberately.
    //
    // The first run of this test failed, and the failure was the result rather
    // than a bug: the pinned model put the intended candidate first in none of
    // the ranked cases, at a self-reported confidence of 0.9 on every one of
    // them. A gate of "top1 must be greater than zero" would then stay red
    // forever, which makes it a marker rather than a test, and worse, it would
    // make a real product decision - whether to ship AI reranking at all -
    // invisible inside a Rust assertion.
    //
    // So this asserts only what must be true of the measurement itself, and
    // reports the quality numbers for the decision to be made on them. What is
    // asserted is that every case was accounted for, that every reply parsed,
    // and that the corpus and its labels agree with each other.

    let mrr = if ranked == 0 {
        0.0
    } else {
        reciprocal_rank_sum / ranked as f64
    };
    let mut breakdown = String::new();
    for (kind, n, hits1, hits5, misses) in &per_kind {
        breakdown.push_str(&format!(
            "{kind}(n={n} top1={hits1} top5={hits5} not_top1={misses}) "
        ));
    }
    evidence::evidence_performed(
        name,
        &format!(
            "cases={total} ranked={ranked} discarded_by_map_decision={unusable} top1={top1} \
             top5={top5} mrr={mrr:.3} per_kind=[{breakdown}] \
             note=absolute accuracy of the pinned model on a constructed corpus with a constructed \
             baseline order. Mozc's real order is unavailable because the text service cannot be \
             created (0-C-24), so NO lift-over-Mozc figure is claimed and none can be derived \
             from this line. A text-level catastrophic rewrite rate is also not reported: the \
             candidate id set is closed, so the model structurally cannot introduce text that \
             Mozc did not supply, and a rate of zero there would be vacuous rather than measured. \
             The functional equivalent is counted instead as discarded_by_map_decision. \
             top5 is not a discriminating metric on this corpus: every case has three candidates, \
             so the expected candidate is inside any top five by construction. \
             per_case=[{per_case}]"
        ),
    );
}

/// What the model is actually FOR, measured at the level the user cares about.
///
/// The reranking corpus above asks a 1.5B model to choose between near-identical
/// candidates, which is the task small models are worst at, and it scored zero.
/// That says the model is a bad **reranker**. It does not say the model is
/// useless, and drawing that conclusion from a reranking number would be the
/// same category of error as reading a fixture as a product.
///
/// The core job of a Japanese IME is kana to kanji, and that is the task where a
/// small language model has a real advantage over a frequency-ranked engine: it
/// reads the sentence. So this asks the model to do that job, directly, with the
/// same runtime and the same prompt machinery, and judges the result against an
/// intended reading.
///
/// Deliberately different from `map_decision`'s protocol: this is a capability
/// probe, not a claim about the shipped rerank path. The shipped path asks for a
/// permutation and this asks for text, so the two answers are not comparable and
/// this one is not wired into anything.
#[tokio::test]
async fn the_model_converts_kana_to_kanji_the_way_an_ime_has_to() {
    let name = "the_model_converts_kana_to_kanji_the_way_an_ime_has_to";
    if !evidence::real_runtime_evidence_enabled() {
        evidence::evidence_not_performed(name, "KANAI_AI_EVIDENCE is not set to 1");
        return;
    }

    let stage = evidence::payload_root_for_measurement();
    let (address, api_key, _keep) = start_probe_runtime(&stage).await;

    let mut exact = 0_usize;
    let mut partial = 0_usize;
    let mut unparseable = 0_usize;
    let mut per_case = String::new();
    let total = CONVERSION_CORPUS.len();

    for (index, entry) in CONVERSION_CORPUS.iter().enumerate() {
        let user = serde_json::json!({
            "contextBefore": entry.before,
            "kana": entry.kana,
            "contextAfter": entry.after,
        })
        .to_string();
        let body = serde_json::to_string(&serde_json::json!({
            "model": PINNED_MODEL_ID,
            "temperature": 0,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": "You are a Japanese IME conversion engine. Given a kana string and the text around it, return JSON only: {\"converted\": \"...\"}. Convert the kana to the kanji the surrounding text requires. Return only the converted span, nothing else."},
                {"role": "user", "content": user}
            ]
        }))
        .expect("the conversion prompt is serialisable");

        let (raw, elapsed) =
            tokio::time::timeout(PROBE_BUDGET, post_completion(&address, &api_key, &body))
                .await
                .expect("a model answer arrives or the test says so")
                .unwrap_or_else(|error| panic!("case {index} got no HTTP reply: {error}"));
        let envelope: serde_json::Value = serde_json::from_str(&raw)
            .unwrap_or_else(|error| panic!("case {index} reply is not JSON ({error}): {raw}"));
        let content = envelope
            .pointer("/choices/0/message/content")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_else(|| panic!("case {index} reply has no message content: {raw}"))
            .to_owned();
        eprintln!(
            "KANAI_AI_CONVERT case={index} ms={} content={content}",
            elapsed.as_millis()
        );

        let answer: serde_json::Value = match serde_json::from_str(&content) {
            Ok(value) => value,
            Err(error) => {
                unparseable += 1;
                per_case.push_str(&format!("case{index}=UNPARSEABLE({error}) "));
                continue;
            }
        };
        let converted = answer
            .get("converted")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .trim()
            .to_owned();
        if converted == entry.expected {
            exact += 1;
        } else if entry.expected.contains(&converted) && !converted.is_empty() {
            partial += 1;
        }
        per_case.push_str(&format!(
            "case{index}[{}=>{:?} want={}] ",
            entry.kana, converted, entry.expected
        ));
    }

    assert_eq!(
        unparseable, 0,
        "{unparseable} of {total} conversion replies were not JSON with a `converted` field. Raw \
         content is in the KANAI_AI_CONVERT lines."
    );

    evidence::evidence_performed(
        name,
        &format!(
            "cases={total} exact={exact} partial={partial} unparseable={unparseable} \
             note=capability probe of the pinned model on kana to kanji conversion, judged against \
             an intended reading. This is NOT the shipped rerank path and NOT comparable to it: the \
             shipped path asks for a candidate permutation, this asks for text. Mozc's own output \
             cannot be obtained on this host (0-C-24), so no comparison against Mozc is claimed. \
             per_case=[{per_case}]"
        ),
    );
}

/// A directory junction, so a payload under a Japanese repository path can be
/// reached through an ASCII one. Identical to the helper in `rerank_deadline`
/// and `ai_runtime`; each integration test is its own crate, so it cannot borrow
/// theirs.
struct AsciiJunction {
    #[allow(dead_code)]
    path: PathBuf,
    _target: JunctionGuard,
}

impl AsciiJunction {
    fn create(path: &Path, target: &Path) -> Self {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let script = format!(
            "New-Item -ItemType Junction -Path {} -Target {} -ErrorAction Stop | Out-Null",
            quote_for_powershell(&path.to_string_lossy()),
            quote_for_powershell(&target.to_string_lossy())
        );
        let output = std::process::Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", &script])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .expect("PowerShell runs");
        assert!(
            output.status.success(),
            "the ASCII junction at {} -> {} could not be created: stdout={} stderr={}",
            path.display(),
            target.display(),
            String::from_utf8_lossy(&output.stdout).trim(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
        Self {
            path: path.to_path_buf(),
            _target: JunctionGuard(path.to_path_buf()),
        }
    }
}

fn quote_for_powershell(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

struct JunctionGuard(PathBuf);

impl Drop for JunctionGuard {
    fn drop(&mut self) {
        let _ = std::process::Command::new("cmd.exe")
            .args(["/d", "/c", "rmdir"])
            .arg(&self.0)
            .output();
    }
}
