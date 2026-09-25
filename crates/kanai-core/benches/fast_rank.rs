use std::hint::black_box;
use std::time::Instant;

use kanai_core::{
    CandidateAdjustments, CandidateOrigin, ConversionCandidate, LocalDataPolicy,
    LocalQualityConfig, LocalQualityEngine, LocalQualityRequest, ModelTier, PersonalizedCandidate,
};

fn candidate(id: i32, text: &str, reading: &str, rank: usize) -> PersonalizedCandidate {
    PersonalizedCandidate {
        candidate: ConversionCandidate {
            id,
            text: text.to_owned(),
            reading: Some(reading.to_owned()),
            provider_rank: rank,
            description: None,
            origin: CandidateOrigin::Conversion,
            attributes: Vec::new(),
            log: None,
        },
        score: 0.0,
        adjustments: CandidateAdjustments {
            mozc: 0.0,
            learning: 0.0,
            domain: 0.0,
            user_word: 0.0,
            context: 0.0,
        },
        explanation: String::new(),
    }
}

fn percentile(values: &[u64], numerator: usize, denominator: usize) -> u64 {
    let index = (values.len() - 1) * numerator / denominator;
    values[index]
}

fn main() {
    const ITERATIONS: usize = 10_000;
    let baseline = vec![
        candidate(0, "今日", "きょう", 0),
        candidate(1, "強化", "きょうか", 1),
        candidate(2, "教育", "きょうiku", 2),
        candidate(3, "公共", "こうきょう", 3),
        candidate(4, "|Pages", "ぺーじ", 4),
    ];
    let mut engine =
        LocalQualityEngine::new(LocalQualityConfig::new(LocalDataPolicy::BoundedContext));
    let mut timings = Vec::with_capacity(ITERATIONS);

    for generation in 1..=ITERATIONS as u64 {
        let request = LocalQualityRequest::new(
            1,
            generation,
            Some(generation),
            ModelTier::Compact,
            "きょう",
        )
        .with_context("昨日の会議では", "を使う")
        .with_revisions(generation, 0);
        let mut candidates = baseline.clone();
        let started = Instant::now();
        let outcome = engine.rank_fast(black_box(&mut candidates), &request);
        timings.push(started.elapsed().as_nanos() as u64);
        black_box(outcome);
    }

    timings.sort_unstable();
    println!(
        "fast_rank: iterations={ITERATIONS} p50_ns={} p95_ns={} p99_ns={} cache_entries={}",
        percentile(&timings, 50, 100),
        percentile(&timings, 95, 100),
        percentile(&timings, 99, 100),
        engine.cache_entries(),
    );
}
