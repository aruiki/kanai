import { useEffect, useState } from "react";
import { createEmptyLearningState } from "./demo";
import type { LearningState, ModelTier, UserProfile } from "./types";

const STORAGE_KEY = "kanai.learning.v1";

function isLearningState(value: unknown): value is LearningState {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Partial<LearningState>;
  const profile = candidate.profile as Partial<UserProfile> | undefined;
  const validTier = ["mozcOnly", "tiny", "compact", "balanced"].includes(profile?.modelTier ?? "");
  const finite = (input: unknown, min: number, max: number) =>
    typeof input === "number" && Number.isFinite(input) && input >= min && input <= max;
  const learned = candidate.learned;
  const userWords = candidate.userWords;
  const history = candidate.history;
  return (
    candidate.version === 1 &&
    typeof profile?.learningEnabled === "boolean" &&
    finite(profile.personalizationStrength, 0, 1) &&
    finite(profile.historyLimit, 1, 500) &&
    Array.isArray(profile.domainTerms) &&
    profile.domainTerms.length <= 100 &&
    profile.domainTerms.every((term) => typeof term === "string" && term.length <= 64) &&
    finite(profile.recencyHalfLifeDays, 1, 3650) &&
    validTier &&
    typeof learned === "object" &&
    learned !== null &&
    Object.keys(learned).length <= 500 &&
    Array.isArray(userWords) &&
    userWords.length <= 200 &&
    Array.isArray(history) &&
    history.length <= 500
  );
}

function loadState(): LearningState {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return createEmptyLearningState("mozcOnly");
    const parsed: unknown = JSON.parse(raw);
    return isLearningState(parsed) ? parsed : createEmptyLearningState("mozcOnly");
  } catch {
    return createEmptyLearningState("mozcOnly");
  }
}

export function usePersistentLearning() {
  const [learningState, setLearningState] = useState<LearningState>(loadState);
  const [storageAvailable, setStorageAvailable] = useState(true);

  useEffect(() => {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(learningState));
      setStorageAvailable(true);
    } catch {
      setStorageAvailable(false);
    }
  }, [learningState]);

  const clearLearning = () => {
    setLearningState((current) => {
      const empty = createEmptyLearningState(current.profile.modelTier);
      return {
        ...empty,
        profile: {
          ...current.profile,
          domainTerms: [],
        },
      };
    });
  };

  const changeModelTier = (modelTier: ModelTier) => {
    setLearningState((current) => ({
      ...current,
      profile: { ...current.profile, modelTier },
    }));
  };

  return { learningState, setLearningState, clearLearning, changeModelTier, storageAvailable };
}
