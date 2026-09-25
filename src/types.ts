export type ModelTier = "mozcOnly" | "tiny" | "compact" | "balanced";

export type Quantization = "notApplicable" | "q4Km" | "q4" | "q5Km";

export interface ModelProfile {
  tier: ModelTier;
  parameters: string;
  quantization: Quantization;
  approximateModelMib: number;
  recommendedRamGib: number;
  contextTokens: number;
  maxOutputTokens: number;
  gpuRecommended: boolean;
}

export interface HardwareCapabilities {
  totalRamGib: number;
  availableRamGib: number;
  logicalCpus: number;
  recommendedTier: ModelTier;
  explanation: string;
}

export interface AppConfig {
  name: string;
  version: string;
  assistantConfigured: boolean;
  assistantModel: string | null;
  assistantEndpoint: string;
  modelProfiles: ModelProfile[];
}

export interface ProviderCapabilities {
  name: string;
  romaji: boolean;
  kana: boolean;
  nBest: boolean;
  context: boolean;
  userDictionary: boolean;
  local: boolean;
}

export interface ProviderHealth {
  available: boolean;
  provider: string;
  detail: string;
  capabilities: ProviderCapabilities;
}

export interface CandidateAdjustments {
  mozc: number;
  learning: number;
  domain: number;
  userWord: number;
  context: number;
}

export type KnownCandidateOrigin =
  | "conversion"
  | "prediction"
  | "suggestion"
  | "userDictionary"
  | "userHistory"
  | "typingCorrection"
  | "spellingCorrection";

export type CandidateOrigin = KnownCandidateOrigin | { unknown: string };

export interface ConversionCandidate {
  id: number;
  text: string;
  reading?: string | null;
  providerRank: number;
  description?: string | null;
  origin: CandidateOrigin;
  attributes: string[];
  log?: string | null;
  score: number;
  adjustments: CandidateAdjustments;
  explanation: string;
}

export interface PreeditSegment {
  value: string;
  reading?: string | null;
  highlighted: boolean;
}

export interface FastRankOutcome {
  status: string;
  changedPositions: number;
  evaluatedCandidates: number;
  cacheEntries: number;
  elapsedMicros: number;
}

export interface ConversionResult {
  provider: string;
  revision: number;
  reading: string;
  preedit: string;
  preeditSegments: PreeditSegment[];
  candidates: ConversionCandidate[];
  focusedIndex: number | null;
  fastRank: FastRankOutcome;
  consumed: boolean;
  elapsed: { secs: number; nanos: number };
}

export type AiRerankStatus =
  | "applied"
  | "abstained"
  | "skipped"
  | "rejected"
  | "unavailable"
  | "timedOut";

export interface AiRerankInfo {
  requestedMode: "off" | "auto" | "onDemand";
  status: AiRerankStatus;
  reasonCode: string;
  model: string | null;
  confidence: number | null;
  changedCandidates: number;
  elapsedMillis: number;
}

export interface ConvertResponse {
  result: ConversionResult;
  state: LearningState;
  ai: AiRerankInfo | null;
}

export interface UserProfile {
  learningEnabled: boolean;
  personalizationStrength: number;
  historyLimit: number;
  domainTerms: string[];
  recencyHalfLifeDays: number;
  modelTier: ModelTier;
}

export interface LearnedCandidate {
  count: number;
  lastUsedAt: number;
  contexts: Record<string, number>;
}

export interface UserWord {
  id: string;
  reading: string;
  text: string;
  boost: number;
  createdAt: number;
}

export interface HistoryEntry {
  reading: string;
  text: string;
  at: number;
}

export interface LearningState {
  version: number;
  profile: UserProfile;
  learned: Record<string, LearnedCandidate>;
  userWords: UserWord[];
  history: HistoryEntry[];
}

export interface AssistResponse {
  text: string;
  provider: string;
  notice: string | null;
}

export interface CommitResponse {
  result: {
    text: string;
    elapsedMillis: number;
  };
  state: LearningState;
}

export type ServiceState = "checking" | "online" | "degraded" | "offline";
