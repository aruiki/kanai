#!/usr/bin/env node

/**
 * KanaAI continuous verification loop.
 *
 * This process never commits, pushes, rewrites source, or disables a failing
 * check. It runs verification gates, writes a heartbeat, and records failures
 * for the active developer/agent to repair. The supervisor restarts this
 * process if it exits or its heartbeat becomes stale.
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, rename, writeFile, appendFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const stateDir = resolve(root, ".development-loop");
const statePath = resolve(stateDir, "state.json");
const logPath = resolve(stateDir, "loop.log");
const startedAt = new Date().toISOString();
const instanceId = randomUUID();
let activeChild = null;
let stopping = false;

function parseArgs(argv) {
  const args = {
    once: false,
    intervalMs: 60_000,
    maxCycles: 0,
    commandTimeoutMs: 15 * 60_000,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--once") args.once = true;
    else if (arg === "--interval-ms") args.intervalMs = Number(argv[++index]);
    else if (arg === "--max-cycles") args.maxCycles = Number(argv[++index]);
    else if (arg === "--command-timeout-ms") args.commandTimeoutMs = Number(argv[++index]);
    else if (arg === "--help" || arg === "-h") args.help = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!Number.isFinite(args.intervalMs) || args.intervalMs < 1000) {
    throw new Error("--interval-ms must be at least 1000");
  }
  if (!Number.isInteger(args.maxCycles) || args.maxCycles < 0) {
    throw new Error("--max-cycles must be a non-negative integer");
  }
  if (!Number.isFinite(args.commandTimeoutMs) || args.commandTimeoutMs < 1000) {
    throw new Error("--command-timeout-ms must be at least 1000");
  }
  return args;
}

function commandPath(name) {
  if (process.env[name.toUpperCase()]) return process.env[name.toUpperCase()];
  if (name === "cargo") {
    const homeCargo = resolve(process.env.HOME ?? "", ".cargo", "bin", process.platform === "win32" ? "cargo.exe" : "cargo");
    if (existsSync(homeCargo)) return homeCargo;
  }
  return name;
}

const cargo = commandPath("cargo");
const commands = [
  { id: "git-diff-check", command: "git", args: ["diff", "--check"] },
  { id: "rust-fmt", command: cargo, args: ["fmt", "--all", "--", "--check"] },
  { id: "rust-clippy", command: cargo, args: ["clippy", "--locked", "--workspace", "--all-targets", "--", "-D", "warnings"] },
  { id: "rust-tests", command: cargo, args: ["test", "--locked", "--workspace", "--all-targets"] },
  { id: "web-tests", command: "npm", args: ["test"] },
  { id: "web-build", command: "npm", args: ["run", "build"] },
  { id: "pages-validation", command: "node", args: ["scripts/validate-pages.mjs"] },
  { id: "quality-evaluation", command: "node", args: ["scripts/run-quality-eval.mjs", "--strict", "--json"] },
];

async function atomicJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await rename(temporary, path);
}

async function record(state) {
  const value = {
    schemaVersion: 2,
    instanceId,
    pid: process.pid,
    startedAt,
    heartbeatAt: new Date().toISOString(),
    ...state,
  };
  await atomicJson(statePath, value);
  await mkdir(stateDir, { recursive: true });
  await appendFile(logPath, `${value.heartbeatAt} ${JSON.stringify({ status: value.status, cycle: value.cycle, failedCommands: value.failedCommands ?? [] })}\n`, "utf8");
}

function runCommand(spec, timeoutMs) {
  return new Promise((resolvePromise) => {
    const commandStarted = Date.now();
    activeChild = spawn(spec.command, spec.args, {
      cwd: root,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;
    const timer = setTimeout(() => {
      timedOut = true;
      activeChild.kill("SIGTERM");
    }, timeoutMs);
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      activeChild = null;
      resolvePromise(value);
    };
    activeChild.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    activeChild.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    activeChild.on("error", (error) => finish({
      id: spec.id,
      ok: false,
      code: null,
      durationMs: Date.now() - commandStarted,
      error: error.message,
      stdout: stdout.slice(-4000),
      stderr: stderr.slice(-4000),
    }));
    activeChild.on("close", (code, signal) => finish({
      id: spec.id,
      ok: !timedOut && code === 0,
      code,
      signal,
      timedOut,
      durationMs: Date.now() - commandStarted,
      stdout: stdout.slice(-4000),
      stderr: stderr.slice(-4000),
    }));
  });
}

function sleep(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

async function runCycle(cycle, timeoutMs) {
  const results = [];
  for (const spec of commands) {
    await record({ status: "running", cycle, currentCommand: spec.id, completedCommands: results.map((result) => result.id) });
    const result = await runCommand(spec, timeoutMs);
    results.push(result);
    process.stdout.write(`[cycle ${cycle}] ${result.id}: ${result.ok ? "PASS" : "FAIL"} (${result.durationMs}ms)\n`);
  }
  const failed = results.filter((result) => !result.ok);
  await record({
    status: failed.length === 0 ? "green" : "needs-repair",
    cycle,
    currentCommand: null,
    completedCommands: results.map((result) => result.id),
    failedCommands: failed.map((result) => result.id),
    results,
    policy: { autoCommit: false, autoPush: false, autoRewriteSource: false, failureAction: "record-and-restart" },
  });
  return failed.length === 0;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log("Usage: node scripts/development-loop.mjs [--once] [--interval-ms N] [--max-cycles N] [--command-timeout-ms N]");
    return;
  }
  console.log(`KanaAI development loop: instance=${instanceId} interval=${args.intervalMs}ms maxCycles=${args.maxCycles || "unlimited"}`);
  console.log("Source is never auto-rewritten; failures are recorded for repair and restart.");
  await record({ status: "starting", cycle: 0, currentCommand: null, failedCommands: [] });
  const requestStop = () => {
    stopping = true;
    if (activeChild) activeChild.kill("SIGTERM");
  };
  process.once("SIGINT", requestStop);
  process.once("SIGTERM", requestStop);
  let cycle = 0;
  while (!stopping && (args.maxCycles === 0 || cycle < args.maxCycles)) {
    cycle += 1;
    await runCycle(cycle, args.commandTimeoutMs);
    if (args.once || (args.maxCycles !== 0 && cycle >= args.maxCycles)) break;
    if (!stopping) await sleep(args.intervalMs);
  }
  await record({ status: stopping ? "stopped" : "complete", cycle, currentCommand: null, failedCommands: [], policy: { autoCommit: false, autoPush: false, autoRewriteSource: false } });
  console.log(`Development loop finished at cycle ${cycle}.`);
}

main().catch(async (error) => {
  await record({ status: "failed", cycle: 0, currentCommand: null, failedCommands: ["loop"], error: error.stack || error.message });
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
