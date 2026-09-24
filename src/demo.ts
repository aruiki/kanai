import type {
  AppConfig,
  ConversionCandidate,
  ConversionResult,
  HardwareCapabilities,
  LearningState,
  ModelProfile,
  ModelTier,
  ProviderHealth,
} from "./types";

export const MODEL_LABELS: Record<ModelTier, string> = {
  mozcOnly: "Mozc Only",
  tiny: "Tiny · 0.6B",
  compact: "Compact · 1.7B",
  balanced: "Balanced · 4B",
};

export const MODEL_DESCRIPTIONS: Record<ModelTier, string> = {
  mozcOnly: "生成AIなし。変換・予測・修復に絞った最軽量モード。",
  tiny: "短い推敲向けの0.6Bクラス。4GB前後のメモリを想定。",
  compact: "再順位付けと段落推敲に適した1.7Bクラス。",
  balanced: "文書全体の支援品質を優先する4Bクラス。",
};

export const MODEL_PROFILES: ModelProfile[] = [
  {
    tier: "mozcOnly",
    parameters: "—",
    quantization: "notApplicable",
    approximateModelMib: 0,
    recommendedRamGib: 0,
    contextTokens: 0,
    maxOutputTokens: 0,
    gpuRecommended: false,
  },
  {
    tier: "tiny",
    parameters: "≈0.6B",
    quantization: "q4Km",
    approximateModelMib: 500,
    recommendedRamGib: 4,
    contextTokens: 2_048,
    maxOutputTokens: 192,
    gpuRecommended: false,
  },
  {
    tier: "compact",
    parameters: "≈1.7B",
    quantization: "q4Km",
    approximateModelMib: 1_200,
    recommendedRamGib: 6,
    contextTokens: 4_096,
    maxOutputTokens: 384,
    gpuRecommended: true,
  },
  {
    tier: "balanced",
    parameters: "≈4B",
    quantization: "q4Km",
    approximateModelMib: 2_700,
    recommendedRamGib: 12,
    contextTokens: 8_192,
    maxOutputTokens: 768,
    gpuRecommended: true,
  },
];

const candidate = (
  id: number,
  text: string,
  reading: string,
  providerRank: number,
  score: number,
  adjustments: ConversionCandidate["adjustments"],
  options: Partial<Pick<ConversionCandidate, "origin" | "attributes" | "description" | "log">> = {},
): ConversionCandidate => ({
  id,
  text,
  reading,
  providerRank,
  score,
  adjustments,
  explanation: "",
  origin: "conversion",
  attributes: ["文脈変換"],
  description: null,
  log: null,
  ...options,
});

export const DEMO_RESULT: ConversionResult = {
  provider: "Mozc · demo fixture",
  reading: "にほんご",
  preedit: "にほんご",
  preeditSegments: [
    { value: "に", reading: "に", highlighted: false },
    { value: "ほん", reading: "ほん", highlighted: false },
    { value: "ご", reading: "ご", highlighted: true },
  ],
  focusedIndex: 0,
  consumed: true,
  elapsed: { secs: 0, nanos: 8_400_000 },
  candidates: [
    candidate(
      101,
      "日本語",
      "にほんご",
      0,
      1_176.2,
      { mozc: 920, learning: 54.2, domain: 0, userWord: 180, context: 22 },
      {
        origin: "userDictionary",
        attributes: ["ユーザー辞書", "学習履歴", "文脈一致"],
        description: "登録済みの変換例が文脈と一致",
        log: "mozc 920.0 + personalization 256.2 → rank 1",
      },
    ),
    candidate(
      102,
      "日本",
      "にほん",
      1,
      497.1,
      { mozc: 460, learning: 18.4, domain: 0, userWord: 0, context: 18.7 },
      {
        origin: "userHistory",
        attributes: ["学習履歴", "文脈変換"],
        description: "前の文で使った表記を優先",
      },
    ),
    candidate(
      103,
      "日本語入力",
      "にほんごにゅうりょく",
      2,
      391.4,
      { mozc: 306.7, learning: 41.8, domain: 36, userWord: 0, context: 6.9 },
      {
        origin: "conversion",
        attributes: ["文脈変換", "専門語"],
        description: "文書内で「入力」という語に関連",
      },
    ),
    candidate(
      104,
      "日本語変換",
      "にほんごへんかん",
      3,
      276.5,
      { mozc: 230, learning: 12.8, domain: 36, userWord: 0, context: -2.3 },
      {
        origin: "conversion",
        attributes: ["文脈変換", "専門語"],
        description: "現在のワークベンチ操作に関連",
      },
    ),
    candidate(
      105,
      "日本語設定",
      "にほんごせってい",
      4,
      181.3,
      { mozc: 184, learning: 0, domain: 0, userWord: 0, context: -2.7 },
      { attributes: ["文脈変換"] },
    ),
    candidate(
      106,
      "日本語文書",
      "にほんごぶんしょ",
      5,
      149.2,
      { mozc: 153.3, learning: 0, domain: 0, userWord: 0, context: -4.1 },
      { attributes: ["予測変換"] },
    ),
    candidate(107, "日本語話", "にほんごはなし", 6, 125.7, {
      mozc: 131.4,
      learning: 0,
      domain: 0,
      userWord: 0,
      context: -5.7,
    }),
    candidate(108, "にほんご", "にほんご", 7, 113.4, {
      mozc: 115,
      learning: 0,
      domain: 0,
      userWord: 0,
      context: -1.6,
    }),
    candidate(109, "日本語話者", "にほんごはっしゃ", 8, 97.5, {
      mozc: 101.7,
      learning: 0,
      domain: 0,
      userWord: 0,
      context: -4.2,
    }),
  ],
};

DEMO_RESULT.candidates[0].explanation = "ユーザー辞書・この文脈での学習を優先しました";
DEMO_RESULT.candidates[1].explanation = "学習履歴・この文脈での学習を優先しました";
DEMO_RESULT.candidates[2].explanation = "文脈変換・専門語を検出しました";
DEMO_RESULT.candidates[3].explanation = "文脈変換・専門語を検出しました";
DEMO_RESULT.candidates[4].explanation = "文脈変換・Mozc の文脈スコアを採用しました";
DEMO_RESULT.candidates[5].explanation = "予測変換・Mozc の文脈スコアを採用しました";
DEMO_RESULT.candidates[6].explanation = "予測変換・Mozc の文脈スコアを採用しました";
DEMO_RESULT.candidates[7].explanation = "文脈変換・Mozc の文脈スコアを採用しました";
DEMO_RESULT.candidates[8].explanation = "予測変換・Mozc の文脈スコアを採用しました";

const DEMO_DICTIONARIES: Record<string, { reading: string; words: string[] }> = {
  henkan: {
    reading: "へんかん",
    words: ["変換", "変更", "編集", "変換表", "変換ルール", "変換候補", "自動変換", "文法変換", "変換エラー"],
  },
  kaihatsu: {
    reading: "かいはつ",
    words: ["開発", "開発部", "開発者", "開発環境", "開発ツール", "開発部会", "開発計画", "開発手法", "開発プロセス"],
  },
  renshuu: {
    reading: "れんしゅう",
    words: ["練習", "練習生", "連載", "研修", "錬成", "修行", "反復練習", "実技練習", "継続練習"],
  },
};

export function createDemoResult(romaji: string): ConversionResult {
  const input = romaji.trim();
  if (input === "nihongo" || input === "にほんご") return DEMO_RESULT;

  const fixture = DEMO_DICTIONARIES[input] ?? {
    reading: input,
    words: [input, `${input}候補`, `${input}変換`, `${input}設定`, `${input}履歴`, `${input}メモ`, `${input}例`, `${input}モード`, `${input}データ`],
  };
  const candidates = fixture.words.map((text, index) => {
    const mozc = 920 / (index + 1);
    const context = index === 0 ? 12.8 : index < 4 ? 5.2 : -2.4;
    const domain = text.includes("変換") || text.includes("開発") ? 24 : 0;
    return {
      ...candidate(
        900 + index,
        text,
        text,
        index,
        mozc + context + domain,
        { mozc, learning: 0, domain, userWord: 0, context },
        {
          origin: index < 3 ? "conversion" : "prediction",
          attributes: domain ? ["文脈変換", "専門語"] : index < 4 ? ["文脈変換"] : ["予測変換"],
          description: index === 0 ? "現在の文書に最も近い変換" : null,
        },
      ),
      explanation: domain
        ? "文脈変換・専門語を検出しました"
        : "Mozc の文脈スコアを採用しました（デモ fixture）",
    };
  });

  return {
    ...DEMO_RESULT,
    reading: fixture.reading,
    preedit: fixture.reading,
    preeditSegments: [{ value: fixture.reading, highlighted: true }],
    candidates,
    provider: "Mozc · demo fixture",
  };
}

export const DEMO_SYSTEM: HardwareCapabilities = {
  totalRamGib: 16,
  availableRamGib: 11,
  logicalCpus: 8,
  recommendedTier: "compact",
  explanation: "RAM 16 GiB / CPU 8 threads から Compact を推奨しました（デモ値）",
};

export const DEMO_HEALTH: ProviderHealth = {
  available: false,
  provider: "Mozc · demo",
  detail: "ローカルAPIへ接続できないため、変換結果を内蔵デモで再生しています。",
  capabilities: {
    name: "Mozc",
    romaji: true,
    kana: true,
    nBest: true,
    context: true,
    userDictionary: false,
    local: true,
  },
};

export const DEMO_CONFIG: AppConfig = {
  name: "KanaAI",
  version: "0.1.0-demo",
  assistantConfigured: false,
  assistantModel: null,
  assistantEndpoint: "http://127.0.0.1:8080/v1",
  modelProfiles: MODEL_PROFILES,
};

export function createEmptyLearningState(modelTier: ModelTier = "mozcOnly"): LearningState {
  return {
    version: 1,
    profile: {
      learningEnabled: true,
      personalizationStrength: 0.68,
      historyLimit: 300,
      domainTerms: [],
      recencyHalfLifeDays: 45,
      modelTier,
    },
    learned: {},
    userWords: [],
    history: [],
  };
}

export function demoAssist(text: string, instruction: string): string {
  const trimmed = text.trim();
  if (instruction.includes("箇条書き")) {
    return trimmed
      .split(/[。\n]/)
      .map((item) => item.trim())
      .filter(Boolean)
      .map((item) => `・${item}`)
      .join("\n");
  }
  if (instruction.includes("要約") || instruction.includes("簡潔")) {
    const firstSentence = trimmed.split("。")[0]?.trim() || trimmed;
    return `${firstSentence}。`;
  }
  if (instruction.includes("丁寧")) {
    return `${trimmed.replace(/[。\s]+$/u, "")}なお、ご確認いただけますと幸いです。`;
  }
  return `整理案:\n${trimmed}`;
}
