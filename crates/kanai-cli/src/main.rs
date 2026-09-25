use std::env;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use kanai_core::{ConversionProvider, ConversionRequest, LearningState};
use kanai_mozc::MozcBridge;

#[tokio::main]
async fn main() -> Result<()> {
    let mut arguments = env::args().skip(1);
    let command = arguments.next().unwrap_or_else(|| "--help".to_owned());
    if matches!(command.as_str(), "-h" | "--help" | "help") {
        print_help();
        return Ok(());
    }

    let bridge = MozcBridge::from_environment();
    let health = bridge.health().await;
    if !health.available {
        bail!("Mozc bridge is unavailable: {}", health.detail);
    }

    if command == "health" {
        println!("{}", serde_json::to_string_pretty(&health)?);
        return Ok(());
    }

    if let Some(raw) = command.strip_prefix("commit:") {
        let candidate_id = raw.parse().context("candidate id must be an integer")?;
        let result = bridge.commit(candidate_id).await?;
        println!("{}", result.text);
        return Ok(());
    }

    let options = arguments.collect::<Vec<_>>();
    let explain = options.iter().any(|value| value == "--explain");
    let json = options.iter().any(|value| value == "--json");
    let context = options
        .into_iter()
        .find(|value| value != "--explain" && value != "--json")
        .map(|value| bounded_context_tail(&value))
        .unwrap_or_default();
    let mut request = ConversionRequest::new(command);
    request.context_before = context;
    let result = bridge.convert(&request).await?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    let mut ranked = LearningState::default().personalize(
        result.candidates.clone(),
        &request.romaji,
        &request.context_before,
        now,
    );
    ranked.sort_by(|left, right| {
        right.score.total_cmp(&left.score).then_with(|| {
            left.candidate
                .provider_rank
                .cmp(&right.candidate.provider_rank)
        })
    });
    ranked.truncate(request.limit);

    if json {
        println!(
            "{}",
            serde_json::json!({
                "result": result,
                "rankedCandidates": ranked,
            })
        );
        return Ok(());
    }

    println!("読み: {}  →  {}", request.romaji, result.preedit);
    for (index, candidate) in ranked.iter().enumerate() {
        println!(
            "{:>2}. {:<24} [{}]",
            index + 1,
            candidate.candidate.text,
            candidate.candidate.id
        );
        if explain {
            println!(
                "    score={:.1}  origin={}  {}",
                candidate.score,
                candidate.candidate.origin.label(),
                candidate.explanation
            );
        }
    }
    println!("elapsed: {} µs", result.elapsed.as_micros());
    Ok(())
}

fn bounded_context_tail(value: &str) -> String {
    const MAX_CONTEXT_CHARS: usize = 32;
    value
        .chars()
        .rev()
        .take(MAX_CONTEXT_CHARS)
        .collect::<String>()
        .chars()
        .rev()
        .collect()
}

fn print_help() {
    println!(
        "KanaAI CLI\n\n  kanai <romaji> [context] [--explain] [--json]\n  kanai health\n  kanai commit:<candidate-id>"
    );
}
