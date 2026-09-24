# KanaAI — ATOK public-product research

**Status:** product research, not reverse engineering
**Research cutoff and access date:** 2026-09-24

This document records only behavior described by JustSystems in public product pages, manuals, and announcements. ATOK is proprietary and is not affiliated with KanaAI. Product names and marks belong to their owners. KanaAI can adopt useful interaction ideas, but it must not copy code, models, dictionary assets, or undocumented implementation details, and must not claim ATOK-equivalent conversion quality without independent testing.

## Executive findings

1. **ATOK's visible IME loop is broader than “type kana, press Space.”** Its public material describes composition, context-aware conversion, learned candidate strength, type-error repair, proofreading, prefix suggestions, next-input prediction, personal and domain dictionaries, per-application behavior, and cloud-assisted services.
2. **Learning is a user-control surface, not a single boolean.** Public help describes per-dictionary-set learning, temporary/weak/strong automatic registration, context examples, user dictionaries, learned “conversion strength,” and ways to suppress or isolate learning.
3. **Personalization has several scopes.** ATOK distinguishes a user dictionary, selectable genre dictionaries, dictionary sets, application/browser-derived context on Windows, and portable cloud synchronization.
4. **ATOK Sync One is an input-state sync product, not merely a dictionary backup.** As documented in September 2026, it synchronizes learned conversion information, commit history, registered words, and deleted words across Windows, macOS, Android, and iOS, with platform-specific limitations.
5. **ATOK MiRA is a separate, user-invoked writing workflow.** It can rewrite an in-progress composition or selected text, accepts presets or a custom instruction, and uses generative AI through the ATOK cloud service. It should not be confused with the latency-sensitive conversion engine.
6. **Public sources do not establish ATOK's proprietary internals.** They do not support claims about a particular model architecture, training corpus, cloud vendor, exact MiRA payload, encryption design, ranking formula, or end-to-end learning pipeline. This document makes none of those claims.

## Publicly documented feature comparison

| Area | What ATOK publicly documents | Responsible reading for KanaAI |
|---|---|---|
| Composition and conversion | Kana/romaji composition, conversion to mixed Japanese text, context-aware candidates, transliteration modes, segmented conversion, and learning that changes candidate strength over time. | Treat composition, conversion, segmentation, and candidate display as separate contracts. Do not infer how ATOK ranks internally. |
| Typing correction | “Deep Collect” and, on Windows, “Personalized Collect” are documented as detecting or repairing likely typing errors, including an intended reading informed by the user's prior input tendencies. | Correction must be explainable and reversible. Keep post-commit proofreading separate from pre-commit conversion repair. |
| Learning | Per-dictionary-set learning writes to a user dictionary; automatic registration can be temporary, weak, or strong; “AI examples” connect neighboring segments; the newer engine also documents learned conversion strength. | Learning should have scope, strength, retention, inspection, export, and deletion controls. Never learn from password or protected fields. |
| Personal dictionaries | A user dictionary stores learned and manually registered words. Users can create/import dictionaries and combine standard, specialist, downloaded, and custom dictionaries in dictionary sets. | Keep a canonical KanaAI store; do not make a third-party engine's private database the only source of truth. |
| Domain dictionaries | ATOK publicly advertises genre dictionaries through “ATOK わたしの辞書プラス”; the Windows page listed 63 genres. Selected genres affect prediction/conversion, and ATOK may recommend genres from registered words and commits. | Domain packs should be independently licensed, removable, and bounded in ranking influence. A genre is not proof that a term is “correct.” |
| Prediction | Prefix suggestions use prior words/short input data; next-input prediction uses the preceding commit. ATOK advertises 2.35 million cloud headwords and learned offline reuse of confirmed cloud words. | Keep local prediction on the key path. Cloud prediction may only add clearly marked, cancellable results after opt-in. |
| Application context | On Windows, “ATOK Insight” can prioritize words found in the application or browser being viewed. ATOK also documents Protect Mode and privacy mode behavior. | Context capture is a high-risk feature. Default to coarse local app profiles; never silently ingest or transmit document text. |
| Cloud sync | ATOK Sync One synchronizes learning, commit history, registered words, and deletions across four OS families; other synchronized items vary by platform. | Sync is opt-in, encrypted, itemized, and independently revocable. It must not be a prerequisite for conversion. |
| Generative writing | ATOK MiRA can rewrite the current composition or a selection, use prompt presets/custom instructions, and offer a “like me” option informed by documented settings/statistics. | Treat generation as an explicit, interruptible side workflow with a preview and provider disclosure—not as a candidate-generation dependency. |

## 1. Composition and conversion

ATOK describes its core job as entering a reading and converting it to kanji/kana text. Its public Windows page says it analyzes the context of text being entered, while the engine page describes the “ATOK Deep Core Engine” as a combination of its conventional kana-kanji conversion and features learned from Japanese text. The same page publishes JustSystems' own comparative claims of roughly 30% fewer conversion errors and roughly 35% better repair rates; these are vendor measurements under unspecified test conditions, not independent evidence and not KanaAI targets ([ATOK engine](https://atok.com/info/features/engine.html), accessed 2026-09-24; [ATOK for Windows](https://atok.com/windows/), accessed 2026-09-24).

The newer **ATOK Hyper Hybrid Engine 2** documentation says that ATOK learns “conversion strength,” not just the last committed word, and tries to avoid letting one recent commit overwhelm a more natural sentence-level result. The public description gives examples involving a learned katakana name in a kana field and a once-used place name versus a frequently used word. This supports one narrow conclusion: ATOK publicly exposes learned strength and recency behavior. It does **not** disclose the underlying scoring algorithm or model ([ATOK engine](https://atok.com/info/features/engine.html), accessed 2026-09-24).

**KanaAI takeaway:** preserve Mozc's tested composition/conversion state machine; add a separate, inspectable KanaAI learning/ranking layer with bounded boosts and an undoable commit log. Do not attempt to recreate ATOK's engine from marketing language.

## 2. Correction, repair, and proofreading

These are related but distinct user-visible jobs:

- **Input repair:** ATOK Deep Collect is documented as automatically repairing typing mistakes. ATOK's published examples include malformed romaji and inferred intended readings ([ATOK engine](https://atok.com/info/features/engine.html), accessed 2026-09-24).
- **Personalized input repair:** a Windows support column says Personalized Collect can use prior input tendencies to infer that one reading was intended rather than another. Its examples include `かくにおねがい` → `かくにんをおねがい` and a valid-looking but wrong idiom spelling. The article explicitly frames this around input repair, not a general prose editor ([Personalized Collect, part 4](https://atok.com/features/column/vol_4.html) and [part 6](https://atok.com/features/column/vol_6.html), accessed 2026-09-24).
- **Proofreading:** ATOK's Windows product page advertises checks for misused idioms, redundant words, honorific usage, nonexistent city names, and katakana phrases, with correction candidates. These are post-text language warnings rather than evidence about how the IME composed the text ([ATOK for Windows](https://atok.com/windows/), accessed 2026-09-24).

**KanaAI takeaway:** never silently replace already committed text. Typing-correction candidates belong in the conversion UI with a reason/confidence indicator; prose and usage issues belong in a separately invoked checker. Corrections should be disable-able per field and globally.

## 3. Learning and the user dictionary

The public Mac help describes a user dictionary as the destination for learned conversion results and manually registered words. Learning is enabled per dictionary set, and its detailed controls include:

- **temporary**: learn in memory only;
- **weak**: learn in memory and automatically register on repeat use; and
- **strong**: automatically register immediately.

The same help describes **AI examples** that relate a committed segment to neighboring segments, and explains that these examples can be learned from commits or entered manually ([dictionary/learning settings](https://atok.com/other/support/howtouse/mac/mn/pgs/mn_tool_ev_dic_d.htm), [detailed learning settings](https://atok.com/other/support/howtouse/mac/mn/pgs/mn_tool_ev_dic_detail.htm), and [glossary](https://atok.com/other/support/howtouse/mac/shrd/shrd_yougo.htm), all accessed 2026-09-24).

The public setting also has a “suppress learning” privacy control. The Windows product page documents privacy mode for browser private windows and Protect Mode during detected online meetings/screen sharing. These are ATOK feature descriptions, not evidence that every platform or edge case behaves identically ([dictionary/learning settings](https://atok.com/other/support/howtouse/mac/mn/pgs/mn_tool_ev_dic_d.htm) and [ATOK for Windows](https://atok.com/windows/), accessed 2026-09-24).

**KanaAI takeaway:** learning must be inspectable and bounded. A committed event should identify the selected surface, reading, scope, and strength without retaining an entire document by default. “Personalized” must never override explicit No Learning, password, secure-input, or Protect Mode choices.

## 4. Personal, domain, and dictionary-set behavior

ATOK publicly distinguishes several dictionary concepts:

- A **user dictionary** receives learning and registrations.
- A **dictionary set** combines standard and other dictionaries; the Mac help documents up to ten sets.
- A user can add downloaded or self-created dictionaries. The help warns that too many active dictionaries can reduce speed and recommends keeping frequently used dictionaries in the base set ([dictionary settings](https://atok.com/other/support/howtouse/mac/mn/pgs/mn_tool_ev_dic_d.htm) and [adding dictionaries](https://atok.com/other/support/howtouse/mac/dc/pgs/dc_dc_add.htm), accessed 2026-09-24).
- The Windows page advertises **ATOK わたしの辞書プラス**, with 63 genre dictionaries at the reviewed date. Selecting a genre makes its terminology available to prediction and normal conversion; ATOK may suggest genres based on registrations and commits ([ATOK for Windows](https://atok.com/windows/), accessed 2026-09-24).
- **ATOK Insight**, documented on the Windows product page, can prioritize words found in the app or browser being referenced. The public page does not specify every collection boundary, retention period, or platform behavior, so those details should not be invented ([ATOK for Windows](https://atok.com/windows/), accessed 2026-09-24).

**KanaAI takeaway:** distinguish global personal entries, opt-in domain packs, and per-application profiles. Apply a capped domain/user boost rather than allowing a pack to monopolize every candidate list. Keep dictionary activation deterministic and show why a domain pack is active.

## 5. Suggestion and prediction

ATOK's glossary distinguishes:

- **suggestion conversion** from a short prefix using previously entered words or abbreviated-input data; and
- **next-input prediction** based on the preceding committed text.

Both are surfaced as conversion candidates. The glossary says commit history can feed suggestions and repeat input, and that its retention is configurable ([ATOK glossary](https://atok.com/other/support/howtouse/mac/shrd/shrd_yougo.htm), accessed 2026-09-24).

ATOK's cloud page documents **ATOK Cloud Suggestion Conversion** on Windows, macOS, and Android. It uses a cloud dictionary, prioritizes genres the user commonly selects, and says a confirmed cloud word is learned on-device for later offline use. The ATOK product home advertises 2.35 million cloud prediction headwords at the reviewed date ([ATOK cloud services](https://atok.com/info/features/cloud.html) and [ATOK product home](https://atok.com/), both accessed 2026-09-24).

“ATOK cloud dictionary” also names licensed reference works such as *Kōjien*, *Daijirin*, and bilingual dictionaries. That lookup service should not be confused with the conversion headword set used by Cloud Suggestion Conversion ([ATOK cloud dictionary](https://atok.com/info/features/dictionary.html), accessed 2026-09-24).

**KanaAI takeaway:** distinguish conversion, prefix suggestion, and next-input prediction in APIs and UI. Cloud results need a visible source and stale-result cancellation; they must never delay a local commit.

## 6. ATOK Sync One

The 2026 feature page says ATOK Sync One launched on Windows, macOS, Android, and iOS on 2026-09-02. Its cross-platform matrix covers:

- conversion-dictionary learning information;
- commit history;
- registered words; and
- deleted words.

Favorite documents are documented for Windows/macOS, and properties/environment settings only for Windows. Mobile learning is limited to the user dictionary in the standard dictionary set. The page also says old ATOK Sync AP data migrates automatically and that the former InternetDisk add-on is no longer required ([ATOK 2026 features](https://atok.com/features/), accessed 2026-09-24).

The cloud-services page states that synchronized server data is retained for 60 days after the last sync. The reviewed public page does not specify a protocol, cryptographic design, conflict model, or statement that sync is end-to-end encrypted; KanaAI must not imply any of those for ATOK ([ATOK cloud services](https://atok.com/info/features/cloud.html), accessed 2026-09-24).

**KanaAI takeaway:** synchronize semantic records, not database files. Use per-record versions/tombstones, explicit item categories, client-side encryption, visible conflict resolution, and independent deletion propagation. A lost encryption key must not silently produce a plaintext fallback.

## 7. ATOK MiRA: the 2026 generative writing assistant

ATOK MiRA expands to **ATOK My Intelligent Rewrite Assistant**. Public documentation places it in the ATOK cloud service, not in the synchronous candidate engine.

### Documented workflow

- Windows launch: 2026-02-02.
- macOS, Android, and iOS launch: 2026-06-29.
- It can rewrite either the current ATOK composition or selected committed text.
- The user can choose prompt presets, enter a custom instruction, or select a prompt-history item.
- The user previews the generated result and explicitly applies it back to the editing application.
- The documented uses include rewriting, review, summarization, idea generation, and changing formality or detail.
- Windows increased the one-request text limit from 300 to 1,000 characters in February 2026, and the product documentation says a daily use limit applies.
- Network connectivity is required.

([ATOK 2026 features](https://atok.com/features/), [cloud services](https://atok.com/info/features/cloud.html), and [JustSystems announcement](https://www.justsystems.com/jp/news/j20251125b.html), all accessed 2026-09-24.)

### “Like me” personalization

With “わたしらしく” enabled, ATOK publicly says its generated prompt is adjusted using documented desktop settings/statistics: punctuation, reading/okurigana behavior, selected personal-dictionary genres, monthly sentence length, and monthly kanji ratio. Mobile uses punctuation settings and selected genre. The page presents examples; it does not disclose a model, the exact full prompt, or a training method ([ATOK 2026 features](https://atok.com/features/), accessed 2026-09-24).

### Limits of the evidence

The public pages reviewed do not identify the model/provider, state whether selected text is used for provider training, specify every field transmitted, document end-to-end encryption, or provide a MiRA-specific retention schedule. ATOK's product home and Passport EULA make broader statements about not collecting personal information or typed words and excluding input/conversion strings from operation logs, but those statements are not a substitute for a detailed MiRA payload/retention specification ([ATOK product home](https://atok.com/), [Passport EULA](https://mypassport.atok.com/eula.html), and [JustSystems privacy policy](https://www.justsystems.com/jp/legal/privacy/), all accessed 2026-09-24). This research does not infer beyond those statements.

**KanaAI takeaway:** a KanaAI writing assistant should show the selected range, instruction, destination provider, and data disclosure before the first send; make generation cancellable; never require it for conversion; default to no style corpus upload; and require a preview before replacement.

## 8. Product principles derived for KanaAI

These are design requirements, not claims of ATOK compatibility:

- **Local first:** Mozc conversion, user learning, dictionaries, prediction, and protection controls work offline.
- **Layered personalization:** global learning, domain packs, per-app profiles, and optional cloud features remain distinguishable.
- **Consent at the boundary:** document context, cloud prediction, sync, and generative writing each require their own control.
- **No silent repair:** candidate correction and post-commit proofreading are separate, visible operations.
- **Bounded influence:** user/domain/cloud scores are capped and auditable; a candidate's source is known internally and can be surfaced in diagnostics.
- **Portable state:** KanaAI owns a documented, encrypted data model rather than coupling users to a vendor's private files.
- **No proprietary imitation:** KanaAI does not use ATOK code, dictionaries, prompts, model outputs, or claimed internal methods.

## Primary sources

All sources were accessed **2026-09-24**.

1. [ATOK — New and added features, 2026](https://atok.com/features/)
2. [ATOK — Cloud services](https://atok.com/info/features/cloud.html)
3. [ATOK — Product home](https://atok.com/)
4. [ATOK — High-accuracy conversion engine](https://atok.com/info/features/engine.html)
5. [ATOK for Windows](https://atok.com/windows/)
6. [ATOK — Cloud dictionary](https://atok.com/info/features/dictionary.html)
7. [ATOK Mac help — Dictionary/Learning settings](https://atok.com/other/support/howtouse/mac/mn/pgs/mn_tool_ev_dic_d.htm)
8. [ATOK Mac help — Detailed learning settings](https://atok.com/other/support/howtouse/mac/mn/pgs/mn_tool_ev_dic_detail.htm)
9. [ATOK Mac help — Dictionary glossary](https://atok.com/other/support/howtouse/mac/shrd/shrd_yougo.htm)
10. [ATOK Mac help — Add a dictionary](https://atok.com/other/support/howtouse/mac/dc/pgs/dc_dc_add.htm)
11. [ATOK — Personalized Collect, part 4](https://atok.com/features/column/vol_4.html)
12. [ATOK — Personalized Collect, part 6](https://atok.com/features/column/vol_6.html)
13. [JustSystems — ATOK MiRA announcement](https://www.justsystems.com/jp/news/j20251125b.html)
14. [ATOK Passport EULA](https://mypassport.atok.com/eula.html)
15. [JustSystems privacy policy](https://www.justsystems.com/jp/legal/privacy/)
