# PRODUCT GOAL

KanaAIは、pinned Mozcを日本語変換基盤として使う、**Windowsで実際にインストールでき、普段の日本語入力として持続利用できる完全ローカルAI IME**である。

完成したKanaAIでは、ユーザーが通常のWindows applicationsでKanaAI日本語IMEを選択し、インストール後の追加開発設定、ブラウザ、CLI、手動でlocal model serverを起動することが不要で、次の状態をすべて観測できる。

- かな・漢字・全角・ASCIIのmode変更、preedit、conversion、candidate paging/selection、Space/Enter/ESC、commit、cancel、undo、IME ON/OFF、focus lossがMozc相当の日常入力として維持される。
- 確定済み文章と近傍の短いcontextをlocalだけで利用し、pinned Mozcが既に生成したcandidateを文脈に応じて安全に再順位付けする。少なくとも、目標contextで有望なcandidateが実機・実candidate fixtureで改善され、無関係なcandidateや確定textをAIが破壊しない。
- key入力とpreedit更新はlarge local modelを待たない。AIのtimeout、process crash、model未導入、broker障害、malformed outputが起っても、Mozcのbaseline candidateと通常の入力操作が継続する。
- ユーザーが実際にcommitしたcandidateだけが学習され、再起動後も個人設定、user dictionary、domain/terminology rankingが残る。candidateを表示しただけでは学習されない。
- raw key、preedit、clipboard、full document、learning dataはproduction pathから外部へ送信されない。password/protected/secure fieldではAI、context、history、learningを停止する。
- Windows 10/11のx86/x64 applicationsで同じlogical IMEがloadされ、install、repair、upgrade、uninstall/reinstallとdaily focus/application restartに必要なscenarioを完了できる。
- model、runtime、Mozc data、installer、configurationはlicenseとintegrityを明示したrelease artifactに含まれ、networkをoffにしてもinstaller後のすべてのcore動作がlocalで完了する。

CLI、HTTP API、browser Workbench、source bridge、mock model、compile-only DLL、静的registration metadata、Unit Test、Linux/WSLでのvertical sliceは開発証拠として有用だが、上記のWindows IMEそのものを代替しない。中間milestone、prototype、source seam、`IsAvailable() == false`、installableでない成果物はcompletion evidenceにならない。

# DEFINITION OF DONE

本プロジェクトは、次の全条件を同じimmutable source commit/tagから、Windows実機/実VM上でIndependent verifierが確認した場合に限り「完成」と宣言できる。

1. `# REQUIRED CAPABILITIES` の全checkboxが、実装と現行の製品scopeに一致してPASSしている。
2. `# ACCEPTANCE TESTS` の全testが、mockではなく実際のinstaller、登録済みTSF TIP、Windows host applications、pinnedMozc、実local modelを使ってPASSしている。
3. `# PERFORMANCE REQUIREMENTS`、`# RELIABILITY REQUIREMENTS`、`# SECURITY / PRIVACY REQUIREMENTS`、`# PLATFORM / ENVIRONMENT REQUIREMENTS`、`# REAL-WORLD VALIDATION` の全gateがPASSしている。
4. clean checkoutからpinnedMozcを含むbuild、test、package、install、quality/performance/security validationが一括再現でき、source treeとverification中にsourceが変化していない。
5. release artifactにはbinary hashes、SBOM、model/dictionary/source licenses、build manifest、再現手順、既知の制限、署名または署名状態と検証方法が含まれる。
6. 既知のcritical/high severity defect、未解決のdata loss/duplicate commit/privacy leak、Installerのpartial registration、cleanup不能なprocess/registry/fileが残っていない。
7. README、安装/upgrade/uninstall、security/privacy、architecture、model/data provenance、既知制限が実際のrelease behaviorと一致している。
8. independent verifierが固定commitのcommand output、test artifact、Windows receipts、quality/performance/security reportsを確認し、root `.goal-complete` を作成する。build agentはgoal completionを宣言できず、`.goal-complete` を作成してはならない。

以下は、それ単独でDONEの根拠にならない。

- code、architecture、protocol、patch、metadata、dashboardの存在
- compilation、lint、unit test、mock、fixture、synthetic corpusのPASS
- CLI/API/Webのdemo
- source-buildableまたは`LoadLibrary`可能だが登録/入力できないTIP
- AIをOFFにしただけで済ませる
- 測定していないlatency、memory、quality値
- 1つのWindows host、1つのapplication、1つのuser profileだけのtest
- fixture側の期待値、gold label、短いcontextへのhard-code、モデル自身のoutputを正解として使うevaluation
- 手動でserver/model/environment variableをsetupする運用
- release branchではないdirty worktreeでのPASS
- documentationだけが存在し、実際の製品機能を代替していない状態

# REQUIRED CAPABILITIES

## Windows product and installation

- [ ] Windows 10/11 x86/x64向けのversioned installerが提供され、clean user/admin profileからKanaAI TSF TIP、x86/x64 runtime、pinnedMozc data、broker/model helper、license/noticeを正しいProgram Files/registry viewへatomic installできる。
- [ ] installerがTSF text service、COM class、language profile、category registration、user/machine activationをreal TSF APIで完了し、prototype registry projectionだけで完了扱いしない。
- [ ] 同じlogical IMEが32-bitおよび64-bit applicationでloadされ、architecture/file redirection/registry viewにsilent mismatchがない。
- [ ] install後は環境変数の手動設定、source path参照、CLI起動、ブラウザ、local HTTP API、userによるmodel server起動なしでIMEを利用できる。
- [ ] repair、upgrade、downgrade policy、uninstall、reinstall、retain/delete profileのchoiceが別操作として検証され、partial install/upgradeから復旧できる。
- [ ] ユーザーはWindowsのlanguage/input method selectorからKanaAIを有効化・解除できる。

## Mozc baseline and native IME behavior

- [ ] PinnedMozcがcomposition、segmentation、conversion、rewriter、dictionary、prediction、commit、undo、user-history authoritative ownerとして保持される。
- [ ] KanaAI AI layerを完全に無効にした場合、preedit、candidate text/rank/cost、segment、commit、undo、mode semanticsが同一binaryのMozc baselineと一致する。
- [ ] Native TSF pathがkeyboard layout、IME ON/OFF、かな/漢字/全角/ASCII、physical key、preedit、inline conversion、candidate paging/selection、Space/Enter/ESC、commit、cancel、undo、reconversion、focus lifecycleを正しく処理する。
- [ ] Candidate IDs、text、reading、rankはrequest/session/generation scopeし、stale、unknown、duplicate、replay、mutated candidateをrejectする。
- [ ] AIはデフォルトでMozcが生成した最大5候補のcomplete permutationへの再順位付けだけを行い、candidate text、commit、mode、cursor、replacement rangeを独自生成/所有しない。
- [ ] User dictionary、domain terms、Mozc history/suggestion/rewriter、system hardware keyboard shortcutsとの衝突がないことをdesktop input testで確認する。

## Local AI and context-aware reranking

- [ ] Windows releaseに含まれる、またはrelease install手順が同一artifactで取得できる、license確認済み・digest固定・version固定のlocal model runtime/modelが存在する。model serverのmanual setupだけを唯一のAI提供方式にしない。
- [ ] Model runtimeはCPU-onlyの宣言済みminimum Windows machineで動作し、GPU(optional)なしでAI featureを利用できる。model load失敗、OOM、low battery、thermal pressureではMozc baselineへ安全にfallbackする。
- [ ] AI inference、disk I/O、logging、update、networkはsynchronous key/preedit callbackから完全に分離される。
- [ ] Candidate resultは、同一session/field/model/learning/candidate snapshotのgenerationに一致し、source vectorがまだ安全な場合だけcurrent candidate listまたはdocumented next-conversion resultへ適用できる。
- [ ] Context/learning fieldはbounded、Unicode-safe、control-freeで、既定最大32 Unicode scalarsの近傍contextを使用する。context取得は別設定で、UI/設定でon/offと使用範囲を説明できる。
- [ ] Contextual rerankはreal pinned Mozc candidate captureで、「昨日こうえんに行った→公園」「大学でこうえんを聞いた→講演」「候補者をこうえんする→後援」を含む複数のunknown caseでtarget contextを実際に再順位付けし、raw readingそのものをcontextに含めるだけでexpected candidateをleakさせない。
- [ ] Model/policyは同一candidate windowのtop-1/top-3/top-5、MRR、NDCG、abstention、target sliceのimprovementをreal held-out corpusで改善し、overall/protected sliceのregression boundを満たす。
- [ ] AI resultはbounded structured outputとしてreason code、model revision、confidence、candidate ID permutationを示し、malformed、low-confidence、unknown ID、duplicate/omitted candidate、stale result、excessive movementをatomic rejectする。
- [ ] Optional modelはcachingできるが、cache keyにmodel revision、reading、bounded context、candidate IDs/text、generation、learning versionを含め、capacity hard limit、invalidation、corruption recoveryがある。

## Fast / slow path and user experience

- [ ] Fast pathはMozc resultとbounded deterministic/neural rankを利用し、local LLMを待たずに有用なpreedit/candidateを返す。
- [ ] Slow pathは別process/task/queueで、bounded request/response size、worker count、queue capacity、deadline、cancellation、backpressureを持ち、saturated queueはbaselineを返す。
- [ ] Timeout、stale、focus loss、session close、model kill、model unavailable、malformed、unknown candidate、semantic assist failureはMozc baseline/last valid resultを保持し、typing/selectionを止めない。
- [ ] AI result delay実験で、key/preedit/candidate windowはmodel completionを待たず、遅れて到着したmodel resultはcommit/next generationを壊さない。
- [ ] Model absent、low-end hardware、battery/thermal degradation時はMozc/direct inputで継続し、無断でremote/cloud providerへswitchしない。

## Personalization and local profile

- [ ] Learningはconfirmed successful local commitまたはexplicit user registration/actionからだけ生成し、display/hover/page/AI suggestion/未commit candidateからは生成しない。
- [ ] Commit rankingそのものはlearning eventを生成せず、undo/deleteはcompensating/tombstone recordで以前の影響を撤回する。
- [ ] User profileはOS user isolation、per-user、versioned、transactional、crash-safeで、Windows credential store (DPAPI/CNG等のapproved design)とauthenticated encryptionを使う。plaintext fallbackは禁止する。
- [ ] Learning aggregates、user words、domain terms、bounded optional historyはMozc終了後も残り、次回起動/再起動後のreal native inputで同じranking priorityを再現する。
- [ ] Canonical KanaAI storeはMozc internal databaseを直接parse/editせず、approved import/projection/isolated profile mechanismを使う。Mozc/upstream historyを二重canonical sourceにしない。
- [ ] Userはlearning global toggle、per-app class、individual delete、history clear、learning reset、domain pack remove、full profile reset、versioned export/importを実行できる。
- [ ] Delete/reset/key lossはreal deletion/isolated fallbackとなり、隠すだけ、plaintext export、recreated history、stale queue resurrectionを起こさない。

## Reliability, native lifecycle, and accessibility

- [ ] Broker、model helper、Mozc server、Windowsのunexpected termination/upgrade/restart後も、未commit preeditが誤commit/重複/lossせず、reconnect後はnew session epoch/generationから安全に再開始する。
- [ ] Failed close, client crash, broker crash, stale pipe、orphan process、cancelled mid-request、indeterminate child responseを含むleak/timeout cleanupが存在する。
- [ ] Native candidate windowはkeyboard/pointer、page keys、DPI/multi-monitor、light dismiss、focus/activation、candidate window position、long candidate、system theme/high contrast/OS accessibilityに正しく追随する。
- [ ] Windows UI Automation/AT-SPI相当のcandidate names、reading、rank、selection、page、focus、preedit/commit statusを実screen reader/accessibility clientで取得・操作できる。
- [ ] Password、protected、direct input、Protect Mode、UAC/elevated、restricted-token/AppContainer、screen sharing/sensitive fieldsで、AI/learning/history/prediction/logging/accessible leakを停止する。
- [ ] Installer後の起動/終了/background auto-start policyがscopeどおりでorphan processを残さず、Windows shutdown/reboot/logonをpassする。

## Privacy, security, and supply chain

- [ ] Production KanaAI IMEはnetwork不要でaccounts不要。composition、reading、context、candidate、learning、history、model prompt/responseをdefaultまたはbackgroundでexternal endpointへ送信しない。
- [ ] Production packageにremote AI assistant、cloud sync、mandatory telemetry、advertising、implicit network featureを含まない。update check(optional)もcontent-freeかつ明示consentでtyped inputを含まない。
- [ ] Local IPCはprivate endpoint、ACL、same-user/session validation、server/client相互authentication、unpredictable capability、bounded framing、replay protectionを持ち、same-user impostorを排除する。
- [ ] FFI/IPC/serialization/import/command parserはlength、UTF-8/UTF-16、range、session/generation、ID permutation、control character、resource exhaustion、malformed inputにfail closedし、fuzz/negative testsを受ける。
- [ ] Stable binaryのlogs/metrics/crash dumpにraw key、preedit、candidate text、context、path/title/URL、model prompt、credential、user dictionary、API keyを載せない。canary packet/log/binary testがこれらを検出する。
- [ ] Model、runtime、Mozc code/dictionary、third-party assetはexact version/digest/source/license/noticeを持ち、redistribution不可能なdataをreleaseへsilent bundleしない。
- [ ] Public releaseにはrelease identity署名を付与し、binary hash/SBOM/provenance、update/rollback、security response/known limitationsを公開する。署名なしの内部buildをpublic completion相当にしない。

## Documentation and user support

- [ ] README/ユーザー documentationにinstall、language profile、initial model setup(手動server無し)、AI ON/OFF、context/privacy、learning controls、recover、uninstall/upgrade、known limitationsを実際のbehaviorで記載する。
- [ ] Build/test/release manifestはfixed source、pinnedMozc、toolchain、architecture、model/dictionary revision/digest、feature flagsを示し、source-only fixture/outputをproduct artifactとmislabelしない。
- [ ] User-facing status/diagnosticsはclipboard/full text/loggingを漏らさず"Why this candidate?"のlocal origin/rankingをboundedに説明できる。

# ACCEPTANCE TESTS

すべてのtestは、明記されたbuild、Windows実user/VM、production package経路で実行する。合成fixtureだけ、mockだけ、source inspectionだけでPASS扱いにしない。

| ID | 初期状態 | Action / input | Expected observable result | Failure condition |
|---|---|---|---|---|
| AT-01 Clean install | Windows 10/11 x86/x64のclean user/admin VM、KanaAI/Mozc dataなし、network任意 | Release installerを実行しscope/activation/architectureを確認する | x86/x64 TIPが正しいProgram Files/registry viewへ入り、TSF/COM/profile/category registration、language layout選択、model/runtime dataがatomic install/activateされる | 手動env、source path、server起動、registry projection、partial file copyが必要、またはinstall failureが残る |
| AT-02 Baseline IME | KanaAI AI OFF / Mozc baseline、Notepad/Edge/Office相当 | かな、漢字、全角、ASCII、preedit、conversion、page、Space/Enter/ESC、undo、IME ON/OFFをtyping | 同一pinnedMozc buildのbaseline text/candidate/cost/commit semanticsと一致し、UIが固まらない | AI OFFがcandidateをdrop/add/change、commit text/offset/undoが一致しない、popup stale |
| AT-03 Context rerank | AI ON、real local model、real applicationで未解決homophone contextをtyping | 「こうえん」等を含む複数unknown corpusをcontext/入力し、candidate window/JSONを記録 | target contextの既存Mozc candidateがexact permutationで改善し、reading/textが同一、reason/confidence/revisionがboundedに可視化される | 3 case hard-code、gold leakage、context/expected stringの直接一致、unknown/duplicate candidate、text mutation |
| AT-04 AI OFF / unavailable | modelをOFF、model fileあり/なし、broker reachable/unreachableのcohort | 同じ入力/操作をAI ON/OFF/未導入で実行 | AI OFFはPinnedMozc baselineと同一order/cost/committed text、base pathは高速で継続 | AI不要時にnetwork/model timeoutを待つ、learnを壊す、candidate textを変更 |
| AT-05 Model kill | real local model processと登録IMEがactive、typed composition途中 | rerank timeout中にmodelをSIGKILL/Task Manager終了、またはresponseをdrop | compositionが継続しMozc candidatesへ安全fallback、kill後の次入力が継続、errorはnon-blocking/content-free | key/selection停止、text loss/duplicate commit、crash、stale result適用、model再起動required |
| AT-06 Slow path | Slow model (minimum 2s) instrumented、current generation candidate表示中 | key入力、conversion、candidate選択、次の入力を重ねる | base candidate/preeditはmodelを待たず、UI/key操作が継続、modelは同一ticketのdeadline後にdiscardまたはdocumented next conversionで反映 | key callbackがawait、max queueがblocked、old resultがnew candidateへattach、late commitでtext change |
| AT-07 Stale/cross-session | 2つ以上のreal TSF sessions、wrong peer/candidate/replay/expired token | generation advance、focus switch、wrong session ID/candidate、replay commitをinject | stale/unknown/duplicate/replay/wrong-peerはcontent-free reject、current sessionのtext/learning/pipeを壊さない | cross-session learning/AI/apply、ID enumeration、public markerだけでaccept |
| AT-08 Confirmed learning | fresh user profile、同一readingに複数Mozc candidates | 別のcandidateを一度表示してから別のtargetをconfirmed commit、IME再起動して同じreadingをtyped | 選択/表示 historyではなくconfirmed commitだけがbounded learningされ、再起動後にtarget rank/理由が再現 | mere show/page/hover/AI rankがlearn、undo後に残存、wrong app/secure fieldからlearn |
| AT-09 Delete/reset | learned data、user words、domain term、pending queue、model cache | 個別delete、history clear、learning reset、full profile reset、key unavailableを各々実行し再起動 | data/queue/cache/derived rankingが実際に消え、Mozc再project、crash recoveryでも復活しない | UI非表示だけ、plaintext fallback、lock/profile inaccessible、partial reset |
| AT-10 Secure field | password/protected/NoLearning/UAC/Protect/AppContainer host、canary string | secure fieldでKanaAIを起動しtyping/conversion/learning/AI/UIA/clipboardを検査 | local AI/model/broker/learning/history/optional telemetryをskipし、Mozc baselineとmode policyを維持、canaryが外部/ログ/accessibilityへ漏れない | 任意request/prompt/persist/log/accessible label、wrong mode、remote send |
| AT-11 Offline / privacy | installed release、network adapter disabled、DNS/packet capture/canary logging | Mozc conversion、context AI、learning、restart/import/export/resetを実行 | 全core動作がlocalで完了、external egress/credential prompt/telemetry/background downloadなし、local encryption/ACL/key storeを確認 | loopback/remote model必須、unbounded fallback network、raw text leak、network必須startup |
| AT-12 Real application matrix | Windows 10/11 x86とx64 hosts、Japanese locale、Notepad/Edge/Office相当、foreground/background/high DPI | 複数window/tab、IME focus switch、candidate UI、commit/undo、app close/reopen、multi-monitor DPI/テーマ/高コントラスト | 全対象でcomposition/candidate/commit/UI/architecture/performance/accessible nameのdesired behaviorを満たし、stale popupがない | one app/one bitnessだけ、major app failure、UI hidden/offscreen/stale、crash |
| AT-13 UIA / accessibility | actual Windows screen reader、UIA InspectまたはAT equivalent、candidate window open | preedit/candidate page/selection/keyboard/pointer/focus lossを移動しscreen readerへLocalized names/stateを読み取らせる | candidate text/reading/rank/selection/page/commit stateがaccessible treeで取得・操作可能、secure field内容なし | `E_NOTIMPL`/stub、keyboard trap、wrong name/AutomationId/state、screen readerが読めない |
| AT-14 Recovery / lifecycle | installed release、multi-session、uncommitted/commit/persist stages | broker、model helper、Mozc server、Windowsを各key/commit/persist/focus境界でkill、repair/upgrade/uninstall/reinstallする | epoch/generation reset、last valid state or direct input、再開後重複/lossなし、orphan/lock/registry残存なし | stale stream/pipe reuse、double commit、text loss、session/tombstone leak、recovery要手動profile repair |
| AT-15 Performance / stress | release installer、declared minimum CPU-only Windows machine、real app/key events | AI OFF/ON、idle/loaded broker、warm/cold、10,000+ events (1,000 warmup) | p50/p95/p99、CPU、working set、queue/cache、drop/fallback/timeout、crash countを保存しperformance/quality gates pass、unbounded growthなし | fast path model wait、threshold breach、memory/FD/queue slope、CI/mock/bridge-only evidence |
| AT-16 Quality corpus | fixed pinnedMozc、1,000+ held-out license-clean Japanese captures、production ranker/model | same binary candidate captureをAI OFF/ONで実行し、stratified slices/seeds/95% CIを保存 | candidate-set equality 100%、overall top1 noninferior、target +2pp、protected slice regression limit、MRR/NDCG/abstention/secure gates pass、human high-severity review 0 | synthetic 14-case only、fixture policy answer、gold in context/model、small cherry-picked corpus、no same-candidate set |
| AT-17 Reproducible release | clean checkout/tag、locked toolchains、fresh caches、no local profile/env/secret | build/package/test/install twice、hash/SBOM/provenance/noticeを比較 | Windows artifactsが再現可能/同一または差異が説明可能、model/data/architecture/source digestがmanifestと一致、user data/credentialをartifactに含まない | dirty tree、floating dep/submodule、missing model/dictionary license、secret/profile/log、clean hostでbuild不能 |

# PERFORMANCE REQUIREMENTS

Performanceのsource microbenchmark、Linux bridge、fixture runtime、CLI/APIはdevelopment signalとして補助的に使用するが、final acceptanceはWindows release installerと実TSF input pathで取得しなければならない。

## 測定方法

- すべての値はrelease build、宣言済みminimum CPU-only Windows reference machine、実TSF host/実application、同一pinnedMozc/model/dictionary revisionで記録する。
- 1,000 warmup events後、AI OFF/ON、broker idle/loaded、warm/cold dictionary、power mode、composition length/kanji/katakana/number/edit/secure slicesを分離して少なくとも10,000 measured eventsを実行する。
- p50/p95/p99、max、CPU time、allocation/queue/cache、working set/peak RSS、process/file handle、timeout/fallback/drop/queue overflowを同じcandidate set/OS/session eventで保存する。
- Reference machine、power mode、model/runtime、dictionary、context設定、instrumentationをbuild manifestとreceiptに含める。数値だけを貼り換えてthresholdを都合よく超えてはならない。

## Latency and responsiveness budgets

| Observable path | Final release gate |
|---|---|
| Native eventからRust receipt | p95 **≤ 1 ms** |
| Key-to-preedit、fast candidate availability | p95 **≤ 3 ms**、AI OFF baseline比でp95 worsening **≤ 5 ms**、broker/model waitなし |
| 通常の≤30文字 compositionのlocal conversion | p95 **≤ 15 ms**、baselineで達成不能なcaseは別途baselineをfixedしてp95 **≤ 100 ms** hard ceilingを超えない |
| Optional local AI rerank result | declared minimum CPU-only AI machineでp95 **≤ 250 ms**、key/preedit budgetをblockしない |
| Commit dispatchからhost insertion success | p95 **≤ 5 ms**、disk/sync/AI/model completionを待たない |
| First useful UI | warm p95 **≤ 750 ms**、cold p95 **≤ 2 s**、超える場合もdirect-input/recovery modeへfallback |
| Any key/candidate wait caused by AI/network/disk | **0 events**。p99 broker/model cleanup allowanceは明示deadline + measured cleanupの範囲内 |

上記budgetが実測で不適切な場合は、completion前に新しいbenchmark evidenceに基づいて**このGOALの明示的なgoal変更**として更新されなければならない。Agentが測定を省略して数値を緩和・削除してはならない。

## Quality / non-inferiority budgets

- Frozen corpusはproduction pinnedMozcから再captureできる1,000+件以上のheld-out compositions/candidate listsを含む。corpus size、slice ratio、model/dictionary revision、seed、gold、capture script、licenseをversion controlへ固定する。
- 少なくとも3-case required examplesに加え、homophone、segmentation、numbers、katakana、ASCII、punctuation、typo、proper nouns、user-approved corrections、edit distanceをstratifyする。policy/modelはgold labelへアクセスしない。
- 同一binary/session/reading/candidate setをAI OFF/ONで比較し、candidate-set equality **100%**、overall top-1 non-inferiority **≤ 1 percentage point**、predeclared target slice top-1 improvement **≥ 2 percentage points**、protected slice top-1 regression **≤ 2 percentage points**を満たす。
- top-k、MRR、NDCG、abstention、timeout/fallback、candidate acceptance/undo、catastrophic rewrite、95% bootstrap confidence intervalを保存し、**minimum quality marginは追加の baseline/benchmark derivationとして独立verifierが承認するまで未確定**。未確定はDONEにできない。
- Synthetic fixture、fixture-declared preference、model自身をjudgeにした結果、短いcontextにgoldを含むtestはquality acceptanceに使えない。

## Memory / resource budgets

- Releaseではqueue、cache、thread、pipe、session、child process、file descriptor、historyのmaximumがboundedである。
- idle→load→idle→focus/upgrade→reopenの複数cohortでworking set/heap/native handle/FD増加を記録し、leak analyzerまたは同等のevidenceでstable plateauを確認する。
- Maximum resident/working set、acceptable leak slope、cache/file budgetは宣言するminimum hardwareで**REQUIRES BASELINE / BENCHMARK DERIVATION**。ただし「一度のRSS差分が小さい」「手動で再起動すれば回復する」はleak PASSにしない。

# RELIABILITY REQUIREMENTS

- Product pathは10,000+ mixed eventsをconcurrent/load条件下でも完走し、typed text loss、duplicate commit、cross-session contamination、unexpected process/file/pipe leak、orphan process、queue/cache overflowをゼロ許容failureとする。
- Broker、Mozc server、model helper、Windows hostのkillを、1,000-event stressのstate boundary（preedit中、convert中、optional rerank中、commit dispatch前後、learning persist前後、focus teardown前後、registration/uninstall中、upgrade途中）ごとに実行する。**再試行回数とacceptance marginはREQUIRES BASELINE / BENCHMARK DERIVATION**で固定し、全cohortがpassする。
- Rust broker、TSF session owner、C++ bridge、Mozc engineのgeneration/state/epoch transitionはtransactionalでなければならない。indeterminate/cancelled child request後はstreamを再利用せず、child/failed flag→bounded restart→new session epochとし、同じsession IDを再利用するstale commandを拒否する。
- Any key/edit/convert/rerank/commit/focus event has an ordered owner. slow AI and model callはkey/edit/commit ownerを保持せず、focus/closeでcancelされ、late responseはcurrent UI/learningを破壊的に変更しない。
- Named pipe/Unix transportはsession lifecycle、client disconnect、slow optional requestと並行key requestを別connection/instanceへdispatchできる。one-request-at-a-time listenerやmodel callによるhead-of-line blockingはacceptance FAILとする。
- Session、tombstone、generation token、pending queue、model request、learning queue、child process、pipe/file lock、temporary profileはlease/idle/focus/disconnect/upgradeでbounded cleanupされる。
- Malformed/oversized/duplicate/unknown/control-character/invalid UTF-8 or UTF-16/invalid range/excessive candidate set/invalid responseはrequest per session atomically rejectし、binary/core processをcrashさせない。
- Store migration、profile import/export、Mozc projectionはtransactional、reversible、crash-safe。Key unavailable/encrypted store corrupt/partial fileはplaintext fallbackではなくbounded degraded mode/明示prompt/resetで、typed inputを止めない。
- Installer registration/category/profile/file copy、upgrade、uninstallはtransactional/idempotent。途中failureでpartial COM/TIP/registry/file stateを残さずrepair可能。
- 再起動/upgrade後はacknowledged commitを重複せず、unacknowledged compositionは保持または明示direct inputへsafe discardし、learning/pending queue/old generationを复活させない。
- ReleaseはWindows Event/log、WER、crash dumpにcontent-freeのreason codeを出し、再現可能なseed/request ID/architecture/session epochを含める。実user text/learning/model payloadを含めない。

# SECURITY / PRIVACY REQUIREMENTS

- Production input process、broker、model helperからInternet/remote loopback listenerへcore conversion/AI/learning requestを送らない。Localhostへの暗黙接続も禁止し、installer時の明示的なasset取得のみを例外として扱う。開発API/Workbench/remote assistはrelease artifactから分離する。
- Current key/preedit/raw composition、clipboard、full document、window title/path/URL、user dictionary/learning corpusはdefault memory-only、永続化/ログ/AI送信しない。Contextは明示local opt-in、最大32 Unicode scalars、current generation限定。
- Password、protected、NoLearning、Protect Mode、UAC/elevated、restricted token、AppContainer、screen-share/secure desktopではAI request、context、history、prediction、sync、telemetry、learningをnative入口でstopする。
- Canonical profileはuser-only ACL、DPAPI/CNG等のOS credential store、authenticated encryption、per-record nonce、schema version、transaction/tombstone/rollbackを持つ。key store障害時plaintext保存/弱いfallbackにしない。
- Native TSF/broker IPCはuser/session-bound、mutually authenticated、protected ACL、cryptographically/unpredictable per-session capability、replay protection、bounded frame/deadline、server process/image identityを検証する。public echo markerやclient IDだけで認証しない。
- Stable buildはno telemetry unless explicit content-free opt-in、C0/C1 contentをlogs/metrics/WER/crash/packet/DNS/binary/CLIに漏らさない。canary stringが全production observable surfacesに現れないことをtestする。
- Model processはread-only model/dictionary/data、最小権限user/filesystem/network policyで動作し、credentialやproduction profileをmodel serverへ渡さない。User-supplied model runnerが任意のnetwork/child processを無制限に起動しないようにする。
- C++/Rust FFI、CBOR/JSON/TSV、pipe、candidate permutations、Mozc bridge、import/export、UI data boundariesはbounds/range/ownership/lifetime exact check。ASan/UBSan（利用可能なtarget）、Windows Application Verifier/Debug sanitizers、fuzz/negative corpusをrelease-critical boundaryへ適用する。
- Model/dictionary/Mozc/dependencyはlicense、source、version、digest、SBOM、notice、redistribution条件を記録する。Secret、API key、user text、profile、local model cacheをsource/CI/artifactへ入れない。
- Release installer、binary、更新packageにはrelease identity署名を付与し、署名できないartifactのpublic releaseを禁止する。SHA-256、SBOM、provenance、rollback、security response、known limitationをrelease channelで公開する。

# PLATFORM / ENVIRONMENT REQUIREMENTS

- **Final acceptance platform:** Windows 10および11に対応したx86/x64 physical machineとclean Windows VM。WSL/Linuxはdeveloper build/testだけnative final evidenceにしない。
- **Required toolchain:** Visual Studio 2022 v143 x86/x64、pin済みWindows SDK、Bazel 9.0.2、pinnedMozc gitlink、reviewed C++/COM/TSF patches。Rust/Node/lockfile/SDK/Bazel versionをrelease manifestで固定し、floating CI resultに依存しない。
- **Application matrix:** Windows 10/11 Notepad, Edge, Office相当（actual Microsoft Officeが許諾/availableならOffice）、32-bitおよび64-bit WPF/Win32/UWP相当host、secure/password test hostを含める。Browser source pageやCLIはtest appに数えない。
- **Locale/input:** Japanese keyboard layout、physical keyboard、hardware/soft IME ON/OFF、candidate window表示環境、high DPI、multi-monitor、light/dark/high contrastを実際のsupported configurationでtestする。
- **AI hardware:** GPUoptional。AIはCPU-onlyの宣言minimum Windows machineでfull local candidate/learning pathを完了し、VRAMに依存しない。具体的なminimum CPU/RAM/model tierは**REQUIRES BASELINE / BENCHMARK DERIVATION**をrelease前に固定し、random CI machineで代替しない。
- **Network:** 1回のrelease validationではoffline/no-DNS/network-blocked cohortを必須とし、同一artifactがmodel download、telemetry、remote APIなしでconversion/ranking/learningを完了する。別online cohortはupdate/asset/document用途だけ。
- **User state:** clean user、安装済み別user、既存Mozc/KanaAI profile、restricted user、multi-sessionをtestし、user dataが他user/other profile/credentialへ漏れない。
- **Developer host:** WSL/Linux compile/test結果、mock loopback、source build、CMake contract test、static UIA/TSF testは補助evidence。Windows registered TIP/real app/real modelで置換しない。
- **Time/environment:** build/test/release metadataにOS build、arch、CPU/GPU、RAM、power、locale、model/dictionary digest、driver/TSF version、application versionを含める。実際の画面/registry操作はaction receiptまたはvideo/scriptで残す。

# REAL-WORLD VALIDATION

以下はsource inspection、unit test、mock、synthetic fixtureで代替できない。

- [ ] Clean Windows userでinstallerを実行し、language profile選択→再起動/instance再起動→actual IME変換→uninstallまでのfull operator journeyを記録する。
- [ ] Windows 10/11 x86/x64でNotepad、Edge、Office相当appを使い、かな/漢字/全角/ASCII、preedit、segment、candidate paging、Space/Enter/ESC、undo、IME toggle、focus/app switch、multimonitorを日本語使用者levelのtrialで確認する。
- [ ] Actual local model processを起動した状態で文脈rerankを体感/測定し、AI OFF/未起動/timeout/killでMozc baselineへ戻ることを確認する。ユーザーがserver、terminal、env fileを手動設定しないことを確認する。
- [ ] 通常の複数working dayをspanするdaily-use trialをpredeclared protocolで実行し、critical/high crash、text loss、duplicate commit、context leak、learning leak、learning unwanted、unrecoverable fallbackを記録する。participant数とtrial durationは**REQUIRES BASELINE / BENCHMARK DERIVATION**、少なくとも一つの通常業務日を含める。
- [ ] Windows screen reader/UIA clientでcandidate window、page、selection、preedit、commit state、secure fieldを読み取り・操作する。keyboard-only、pointer-only、high DPI、light/dark/high contrastを確認する。
- [ ] Secure password/protected/UAC/elevated/restricted-token/AppContainer scenarioをreal Windows host/ applicationsで行い、no outbound model request/no learning/no accessibility leakを確認する。
- [ ] Model/broker/Mozcをreal process kill、OS reboot、app crash、focus loss、upgrade interruptionから複数回recoveryし、content safe/duplicateなし/old process/pipe/registryの残存なしを確認する。
- [ ] Release artifactを別machine/別userへ導入し、checksum、model/data、license、install、profile、rollback、repair、uninstall、user data保持/削除を再確認する。
- [ ] Each validationはsource commit、TIP/installer/model/data hashes、OS/arch/app versions、test steps、expected/observed、video/log/JSON/CSV receipt結び付ける。開発agentの自述や既存`PASS`表示だけでreal validationにしない。

# NON-GOALS

- CLI、HTTP API、browser Workbench、mock、source bridge、Linux/WSL integration test、主要コードのsource seamをend-user IME/release artifactにすること。
- Mozc辞書・変換・形態素・OS integrationの独自全面再実装。KanaAIは既存Mozcを置き換えない。
- Google Japanese Input、ATOKまたは他のproprietary binary、dictionary、data、prompt、private algorithm、UIのcopy、reverse engineering、undisclosed specの再現。
- Cloud AI、hosted conversion、mandatory account、remote sync、telemetry、advertising、implicit background data送信。optional writing assistant/chat productもこのgoalの完了条件ではない。
- Windows ARM64 native TIP、iOS/Android keyboard、Linux Fcitx5/IBus、macOS InputMethodKitのpublic releaseはfuture scopeであり、Windows IMEのcompletionをその未実装で回避するdummyにはしない。
- 大規模モデルの全key同期、free-form chat入力、無制限のcandidate/rewrite生成、AIによる確定textの自動commit/undoの乗っ取り。
- Foundation modelのtraining from scratch。Local AI runtime、quality、ranking、learning、fallback、packagingが要件であり、巨大なtraining projectをdefault scopeにはしない。
- 完全なenterprise management、commercial support、accessibility certification、multi-device syncをこの最初のWindows完了gateへ暗黙に追加すること。ただしenterprise/OS必須security/accessibility testは既に要求する。
- 既存ユーザーMozc profileのtransparent direct DB改変。Canonical KanaAI storeとapproved projection/import boundaryを維持する。

# CONSTRAINTS

## Hard constraints

- **Product:** user-facing final stateはinstallable Windows TSF IMEであり、CLI/API/lab aloneをproduct呼び出ししない。
- **Foundation:** pinnedMozc owns baseline composition/conversion/dictionary/history/completion; KanaAIはnarrow orchestration/ranking/learning/local AI/privacy layer。KanaAI-owned C++→Rust移植はbenchmark/conservation理由が必要。
- **Execution:** key/preedit/typing/commit pathはblocking model/network/remote callを持たない。AI failureはMozc/direct inputへsafe fallbackする。
- **Privacy:** production typing/conversion/AI/learning dataはlocalで処理し、個人情報をexternalへsendしない。secure/Protect fieldsはAI/learning/historyをstopする。
- **State authority:** native shellはOS text insertion/replace boundary、session/generation ownerはRust、conversion/rewrite/dictionaryはMozc、AIはcurrent-generation bounded decisionのみ。
- **Quality:** real pinnedMozc candidate equality、held-out quality、non-inferiority、untrusted/stale result rejectionをevidence required; synthetic/demo alone不可。
- **Distribution:** Windows installer、TSF registration、model/data/runtime、license/SBOM/hash、upgrade/uninstall、actual app evidence是不可避。
- **Licensing:** Mozc BSD-family codeとmixed dictionary/model/dependency noticesを保持し、redistributabilityを仮定しない。proprietary data/modelをsource/artifactに無断で含めない。
- **Verification:** build agentはgoal completionを宣言せず、`.goal-complete`を作らない。独立verifierがimmutable treeで全gateを確認する。
- **Scope integrity:** difficult/native/security/quality/packaging workを「後でpreview/optional/非対象」にsilent downgradeしない。

## Important preferences

- Rust owns orchestration、ranking、cache、learning、privacy、local inference integration、fast data path。C++/COM owns TSF ABI/platform glue。TypeScript owns lab only。
- Quality referenceはmature Japanese IME/実利用感でATOK/Google parityのclaimではなく、reproducible Mozc baseline comparisonを使う。
- AI outputはstructured、bounded、explainable、abstain可能; user accepts candidate through normal commit、model does not own input state。
- Every material performance/security/privacy decisionはbefore/after evidenceとtradeoff reviewを持つ。One-shot benchmark/micro latencyよりactual key path優先。
- User/profile controls、data deletion、accessibility、clear recovery/high quality candidate UIを優先する。
- Code changesはsmall/reviewable、pinned submodule/toolchain/dependency/licensingを不用意に変えない。Developer preview/Mock/Hackはproduction proofとして不可。

# COMPLETION GATES

すべてuncheckedで開始し、actual evidenceを添付した項目だけcheckする。

## Source and reproducibility

- [ ] `GOAL.md`, `AGENTS.md`, `STATE.md`, `VERIFICATION.md`が存在し、final source scope/known gaps/next actionが一致する。
- [ ] Protected release commit/tagとclean worktreeがあり、developer/verifierによってsource/artifactが同時に変更されていない。
- [ ] `third_party/mozc` gitlink、Bazel、Rust、Node、Windows SDK/MSVC、model/runtime/dictionaryのversion/digest/noticeをrelease manifestに固定。
- [ ] Locked clean buildがWindows x86/x64で2回以上再現でき、hash/SBOM/provenance、build log、test artifactをrelease evidenceとして保存。
- [ ] `cargo fmt --all -- --check`、locked workspace Clippy `-D warnings`、debug/release unit/integration test、real Mozc bridge testがPASS。
- [ ] Node/TypeScript lab build/testがPASSし、production packageにlab/browser assetsが入っていない。
- [ ] Bazel patch replay、Mozc bridge/TSF overlay build、C++ contract/UIA/registration testsがLinuxとWindows appropriate hostでPASS。
- [ ] Rust/C++/TSF/IPC/protocol/model integration testがreal fixed artifactsに対してPASSし、mockをautomatic real acceptanceにfallbackしない。

## Native Windows IME

- [ ] Real TIP x86/x64がclean buildから生成、PE/export/dependency/COM loadをpassし、`IsAvailable()` falseのinert seamではない。
- [ ] TSF text service/input profile/category registration、activation/unactivation、language layout、x86/x64 apps loadをWindows API/registry/TSF hostで確認。
- [ ] Native key/edit/preedit/conversion/candidate/commit/cancel/undo/focus/reconnect pathがactual Windows appsで機能。
- [ ] `SessionBinding`/generation/field-class/epoch/tokenはtrusted ownerだけが発行/applyし、cross-session/replay/stale/malformed/mutated candidateがnative pathでreject。
- [ ] AI OFFが同一pinnedMozcのbaseline text/rank/cost/undoと一致。AI ONはcurrent/next conversionのexact bounded permutationで、文脈改善とMozc fallbackをnativeから観測。
- [ ] Slow modelがkey/preedit/commit/UIをblockせず、optional resultはsafe deadline/cancellation/stale policyを持つ。
- [ ] Notepad/Edge/Office相当/32-bit/64-bit/high DPI/secure/protected/UIA/elevation/app-container testがPASS。
- [ ] Broker/model/Mozc kill、reboot、upgrade/uninstall/reinstall testがtext loss/duplicate/cross-session/orphanなしでPASS。

## AI quality and learning

- [ ] Frozen 1,000+ held-out real pinnedMozc corpusと3+ required contextual cases、unknown/stratified slices、license/digest/scriptが保存。
- [ ] Same binary/candidate set AI OFF/ON quality reportがtop-k/MRR/NDCG/95% CI、candidate equality、non-inferiority、target improvement、protected-slice bound、human reviewをpass。
- [ ] Local model/runtimeがrelease install経路でprovisionされ、CPU-only offline process kill/timeout/malformed/low resource fallbackがpass。
- [ ] Confirmed commit-only learning、no display learning、undo/delete/compensation、profile encryption/ACL/key store、restart projection、individual/reset/export/importがpass。
- [ ] Context/privacy、secure field、no learning、bounded context、no network、local user isolation、canary no-leak testsがpass。

## Performance and reliability

- [ ] Declared reference Windows machineで1,000 warmup+10,000 measured events、p50/p95/p99/max、CPU/memory/queue/cache/FD/timeout/fallback cohortsが保存。
- [ ] Key-to-preedit、conversion、commit、startup、optional model latencyがPerformance Requirementsのgateをpass。AI/network/diskのkey path block 0件。
- [ ] Baseline/AI、idle/loaded、warm/cold、同等candidate set比較があり、memory/FD/process/queue leak plateauがevidenceでpass。
- [ ] Boundary fault injection (absent/busy/delayed/crash/oversized/wrong ID/duplicate/partial/malformed/secure)全件でMozc baseline/typing継続。
- [ ] Crash/upgrade/recovery/repair/uninstall/reinstallがcritical/high bug/duplicate/loss/orphanなしでpass。
- [ ] No known critical/high defect。各findingはfix/verified regression test/accepted residual riskの記録を持つ。

## Security, privacy, packaging, and support

- [ ] Threat model、FFI/IPC/store/import/export/model/process/UI privacy review、fuzz/negative/resource-limit testがpass。
- [ ] Named pipe/session capability ACL/peer/server/client identity/replay/concurrency/timeout testがpass。Same-user impostor/pipe squatting/serial slow requestを排除。
- [ ] Stable artifactのcanaryがlogs/metrics/WER/crash/packet/DNS/binary/file/profileへ残らず、raw key/preedit/context/user dataを保存しない。
- [ ] Model/dictionary/data/dependency licenses、SBOM、notices、source/digest、known limitations、security response、privacy noticeがreleaseと一致。
- [ ] Installer/signature/hashes/provenance/rollbackがappropriateで、public releaseはtrusted signing identityを持ち、unsigned artifactをproduction扱いしない。
- [ ] Fresh profile、existing profile、different user、offline install/upgrades、retain/delete profile、uninstall/reinstall/rollbackがactual Windowsでpass。
- [ ] README/user guide/build/install/test/architecture/privacy/model data/known limitationsがrelease behaviorを正確に説明し、source-only successを作らない。
- [ ] Real-world daily-use validationがpredeclared protocol/result/media/artifactを残してcritical/high observationなし。
- [ ] Independent verifierが固定commitで全command/result/artifactを再確認し、critical/high bugなしとroot `.goal-complete` を作成。

# BLOCKERS REQUIRING HUMAN ACTION

以下だけ genuinely human/external actionを要求する。implementation/verificationを理由にdon’t stopしない。

- Trusted Windows code-signing certificate、publisher identity、timestamping、SmartScreen/App Control distribution policyの承認/取得。Candidate product完成にはrelease-signing gateと同一の権限が必要。
- Machine-wide TSF registration、restricted token/AppContainer/UAC/secure desktop test、physical/VM Windows 10/11 machines、Office/Edge/actual screen readerなど、agentが安全にautomated/accessibly操作できないreal host管理者/operatorの協力。
- 実model/runtime/dictionary/Mozc data/GGUF/AI weightsのredistribution license、source offer、商用/非商用、privacy training data条件の法的/owner approval。ライセンス/配布不可ならagentは法的許諾のある代替またはlocal user-supplied licensed packageの実装を選び、3つの選択肢を勝手に「download required」に変えない。
- Branding/CLSID/language profile/publisher name/terms/privacy operator/contact final approval。これはtechnical requirementを削除する理由にはできず、agentはreviewed candidate Identity/evidenceを用意して提示する。
- Real-world daily-use trialの参加者/端末/利用時間/handling of user textを安全に行えるtest plan提供およびconsent。人数/時間/privacyの具体値はcompletion前に明示decisionが必要。
- Windows update/policy/managed-environment提供者が外部制限/署名/privileged testをuser側で許可しない場合、agentはそのreal resultを記録し、fake pass/feature disable/scope downgradeをしない。

# ANTI-GOAL-DRIFT RULES

1. Future agentsはimplementation strategy、architecture、language、model choice、packagingをverifiable evidenceで変更できるが、`PRODUCT GOAL`をsilently weaken、narrow、replaceしてはならない。
2. Difficult requirements（native TSF、real installer、real model、quality corpus、encrypted learning、security、accessibility、performance、real app validation、licensing）は理由がない限りrequirementであり、prototype/preview/mock/non-goal/optional futureへ移さない。
3. Partial implementation、one app、one architecture、one OS build、one user、one model mock、one unit test、source seam、metadata statusをcompletion/Native beta/full releaseに再定義しない。
4. Tests/moocks/stubs/static checksはrequested real behaviorをexerciseしない場合、final real-integration acceptanceを満たさない。Mockはfailure/safety contractのtest assistantにはなってもfinal model/IMEの代替にはならない。
5. 3 case、fixture-declared policy、gold-containing context、synthetic candidate set、same model generated answer、cherry-picked casesだけでcontext/learning/qualityをpassさせない。Real pinned Mozc、same binary/candidate set、held-out/license-clean corpusとproduction pathを使う。
6. Checked requirementは後のevidenceで実際にimplement/validateされていないと判明した場合、reopenし、failure/partialとして記録する。「/sourceにある」「metadata true」「previous agent PASS」だけで閉じ直さない。
7. Completionはactual commands/logs/exit status、binary/hash/model/data digest、quality JSON/CSV、performance receipts、TSF registration/host screenshots、installer/uninstall evidence、independent verifier reportなどimmutable evidenceによる。Narrative/self-assessment/screenshot without machine receiptだけで不可。
8. Dirty worktree、同時developer source変更、floating dependency/submodule/toolchain、local-only cache、unreviewed generated binaryをrelease evidenceにしない。Verification snapshotをsource/artifact manifestで固定する。
9. Performance/quality/security claimはAI OFF baseline、real model、real Windows、production candidate/profile、fixed corpus、declared hardware、p50/p95/p99/CI/10,000-event等、関連gateが全てcorresponding cohortでpassした場合のみ許す。Bridge/API/mock/lab resultをrelease resultとして代用しない。
10. AI fallback/ON/OFF、remote/network、secure field、learning、upgrade/uninstallを隠れたswitchやcompletionからのsilent exclusionでgateをgreenにしてはならない。すべての機能とfallbackを明示的に検証する。
11. User personal data、raw key/preedit/context、learning/model prompt/response、credential、real dictionary/model fileをsource、test fixture、logs、artifact、public issueへreleased/committedしない。Canary/synthetic dataを使い、security reviewを通したredacted evidenceだけpreserveする。
12. `GOAL.md`の変更はdiff/理由/impactを明示し、scope/quality/performance/security/privacy/deletion/validationを弱める変更にはuserの明示decision/承認を必要とする。任意のagent都合でrequirements/checkboxを消さない。
13. Milestone完了はplanning/progressに過ぎない。`COMPLETION GATES`全てとindependent verifierの`.goal-complete`以外に「完成」「production-ready」「final」「beta」等のclaimを置いてはならない。
14. Final release artifactsはactual user journey、改善、failure recovery、uninstallまで観察できる。不能なOS権限/signing/legal/physical validationはcheck boxをpretend passさせず、BLOCKERS/STATE/VERIFICATIONに正確に記録する。
15. Future scope (Linux/macOS/ARM64/sync/writing assistant等)を追加することは許されるが、Windows core completionをそのfuture featureの未実装で延期・無限化してはならない。
