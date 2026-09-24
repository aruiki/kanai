import { describe, expect, it } from "vitest";
import { createDemoResult, demoAssist, MODEL_PROFILES } from "../src/demo";


describe("KanaAI workbench fixtures", () => {
  it("keeps a usable candidate list when the local API is unavailable", () => {
    const result = createDemoResult("にほんご");
    expect(result.provider).toContain("demo");
    expect(result.preedit).toBe("にほんご");
    expect(result.candidates.length).toBeGreaterThan(3);
    expect(result.candidates[0].text).toBe("日本語");
  });

  it("exposes all model tiers with a zero-model baseline", () => {
    expect(MODEL_PROFILES.map((profile) => profile.tier)).toEqual([
      "mozcOnly",
      "tiny",
      "compact",
      "balanced",
    ]);
    expect(MODEL_PROFILES[0].approximateModelMib).toBe(0);
    expect(MODEL_PROFILES[1].approximateModelMib).toBeLessThan(
      MODEL_PROFILES[2].approximateModelMib,
    );
  });

  it("provides deterministic local fallback writing actions", () => {
    expect(demoAssist("一文目。二文目。", "箇条書きにする")).toContain("・");
    expect(demoAssist("今日は資料を確認しました。", "簡潔にまとめる")).toContain("。");
  });
});
