import type {
  AppConfig,
  AssistResponse,
  CommitResponse,
  ConvertResponse,
  HardwareCapabilities,
  LearningState,
  ProviderHealth,
} from "./types";

const DEFAULT_REQUEST_TIMEOUT_MS = 4_000;

export class ApiError extends Error {
  readonly status: number;

  constructor(message: string, status = 0) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function parseError(response: Response): Promise<string> {
  const body: unknown = await response.json().catch(() => undefined);
  if (isRecord(body) && typeof body.error === "string") {
    return body.error;
  }
  return `${response.status} ${response.statusText || "Request failed"}`;
}

async function request<T>(
  path: string,
  init?: RequestInit,
  timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
): Promise<T> {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
  const headers = new Headers(init?.headers);
  if (init?.body) headers.set("Content-Type", "application/json");

  try {
    const response = await fetch(path, {
      ...init,
      headers,
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new ApiError(await parseError(response), response.status);
    }
    return (await response.json()) as T;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new ApiError("ローカルAPIがタイムアウトしました", 408);
    }
    throw new ApiError(error instanceof Error ? error.message : "ローカルAPIに接続できません");
  } finally {
    window.clearTimeout(timeout);
  }
}

export function fetchHealth(): Promise<ProviderHealth> {
  return request<ProviderHealth>("/api/health", undefined, 1_500);
}

export function fetchSystem(): Promise<HardwareCapabilities> {
  return request<HardwareCapabilities>("/api/system", undefined, 1_500);
}

export function fetchConfig(): Promise<AppConfig> {
  return request<AppConfig>("/api/config", undefined, 1_500);
}

export function postConvert(
  romaji: string,
  contextBefore: string,
  contextAfter: string,
  state: LearningState,
): Promise<ConvertResponse> {
  return request<ConvertResponse>(
    "/api/convert",
    {
      method: "POST",
      body: JSON.stringify({
        romaji,
        contextBefore,
        contextAfter,
        limit: 9,
        aiMode: "auto",
        state,
      }),
    },
    8_000,
  );
}

export function postAssist(
  text: string,
  instruction: string,
  personalize: boolean,
  state: LearningState,
): Promise<AssistResponse> {
  return request<AssistResponse>(
    "/api/assist",
    {
      method: "POST",
      body: JSON.stringify({ text, instruction, personalize, state }),
    },
    36_000,
  );
}

export function postCommit(
  candidateId: number,
  reading: string,
  expectedText: string,
  context: string,
  state: LearningState,
): Promise<CommitResponse> {
  return request<CommitResponse>(
    "/api/commit",
    {
      method: "POST",
      body: JSON.stringify({ candidateId, reading, expectedText, context, state }),
    },
    8_000,
  );
}

export function postUserWord(
  reading: string,
  text: string,
  boost: number,
  state: LearningState,
): Promise<{ state: LearningState }> {
  return request<{ state: LearningState }>("/api/user-words", {
    method: "POST",
    body: JSON.stringify({ reading, text, boost, state }),
  });
}

export function postRemoveUserWord(id: string, state: LearningState): Promise<{ state: LearningState }> {
  return request<{ state: LearningState }>("/api/user-words/remove", {
    method: "POST",
    body: JSON.stringify({ id, state }),
  });
}
