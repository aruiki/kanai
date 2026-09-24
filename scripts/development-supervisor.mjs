#!/usr/bin/env node

/**
 * Restarting supervisor for development-loop.mjs.
 * It never changes source or executes repairs; it restores the verification
 * process after crashes, exits, or stale heartbeats.
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const loopScript = resolve(root, "scripts/development-loop.mjs");
const stateDir = resolve(root, ".development-loop");
const supervisorStatePath = resolve(stateDir, "supervisor-state.json");
const lockPath = resolve(stateDir, "supervisor.lock");
const logPath = resolve(stateDir, "supervisor.log");
const instanceId = randomUUID();
let child = null;
let stopping = false;
let restarts = 0;
let lastExitCode = null;
let lastExitSignal = null;
let lastError = null;
let startTimer = null;

function parseArgs(argv) {
  const args = {
    intervalMs: 60_000,
    maxCycles: 0,
    staleMs: 15 * 60_000,
    commandTimeoutMs: 15 * 60_000,
    backoffMs: 5_000,
    maxRestarts: 0,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--interval-ms") args.intervalMs = Number(argv[++index]);
    else if (arg === "--max-cycles") args.maxCycles = Number(argv[++index]);
    else if (arg === "--stale-ms") args.staleMs = Number(argv[++index]);
    else if (arg === "--command-timeout-ms") args.commandTimeoutMs = Number(argv[++index]);
    else if (arg === "--backoff-ms") args.backoffMs = Number(argv[++index]);
    else if (arg === "--max-restarts") args.maxRestarts = Number(argv[++index]);
    else if (arg === "--help" || arg === "-h") args.help = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  for (const [name, value] of Object.entries({ intervalMs: args.intervalMs, staleMs: args.staleMs, commandTimeoutMs: args.commandTimeoutMs, backoffMs: args.backoffMs })) {
    if (!Number.isFinite(value) || value < 1000) throw new Error(`--${name} must be at least 1000`);
  }
  if (!Number.isInteger(args.maxCycles) || args.maxCycles < 0) throw new Error("--max-cycles must be a non-negative integer");
  if (!Number.isInteger(args.maxRestarts) || args.maxRestarts < 0) throw new Error("--max-restarts must be a non-negative integer");
  return args;
}

async function atomicJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await rename(temporary, path);
}

async function log(message) {
  await mkdir(stateDir, { recursive: true });
  await appendFile(logPath, `${new Date().toISOString()} ${message}\n`, "utf8");
}

async function writeState(status, extra = {}) {
  await atomicJson(supervisorStatePath, {
    schemaVersion: 1,
    instanceId,
    pid: process.pid,
    status,
    updatedAt: new Date().toISOString(),
    loopPid: child?.pid ?? null,
    restarts,
    maxRestarts: extra.maxRestarts ?? null,
    lastExitCode,
    lastExitSignal,
    lastError,
    ...extra,
  });
}

function processAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function acquireLock() {
  await mkdir(stateDir, { recursive: true });
  if (existsSync(lockPath)) {
    try {
      const lock = JSON.parse(await readFile(lockPath, "utf8"));
      if (processAlive(Number(lock.pid))) throw new Error(`development supervisor already running: pid ${lock.pid}`);
    } catch (error) {
      if (String(error.message).startsWith("development supervisor already running")) throw error;
    }
  }
  await atomicJson(lockPath, { pid: process.pid, instanceId, startedAt: new Date().toISOString() });
}

async function releaseLock() {
  try {
    const lock = JSON.parse(await readFile(lockPath, "utf8"));
    if (lock.instanceId === instanceId) await writeFile(lockPath, "", "utf8");
  } catch {
    // Best effort during recovery.
  }
}

async function startChild(args) {
  if (stopping) return;
  child = spawn(process.execPath, [
    loopScript,
    "--interval-ms", String(args.intervalMs),
    "--max-cycles", String(args.maxCycles),
    "--command-timeout-ms", String(args.commandTimeoutMs),
  ], {
    cwd: root,
    env: process.env,
    stdio: "inherit",
    windowsHide: true,
  });
  await writeState("starting", { maxRestarts: args.maxRestarts });
  log(`started loop pid=${child.pid} restart=${restarts}`);
  await writeState("running", { maxRestarts: args.maxRestarts });
  child.once("error", async (error) => {
    lastError = error.message;
    await writeState("child-error", { maxRestarts: args.maxRestarts });
  });
  child.once("exit", async (code, signal) => {
    lastExitCode = code;
    lastExitSignal = signal;
    child = null;
    if (stopping) {
      await writeState("stopped", { maxRestarts: args.maxRestarts });
      return;
    }
    restarts += 1;
    if (args.maxRestarts !== 0 && restarts > args.maxRestarts) {
      stopping = true;
      await writeState("restart-limit", { maxRestarts: args.maxRestarts });
      await log(`restart limit reached code=${code} signal=${signal}`);
      return;
    }
    await writeState("restarting", { maxRestarts: args.maxRestarts });
    await log(`loop exited code=${code} signal=${signal}; restart in ${args.backoffMs}ms`);
    startTimer = setTimeout(() => { void startChild(args); }, args.backoffMs);
  });
}

async function readLoopHeartbeat() {
  try {
    return JSON.parse(await readFile(resolve(stateDir, "state.json"), "utf8"));
  } catch {
    return null;
  }
}

async function staleWatch(args) {
  setInterval(async () => {
    if (stopping || !child) return;
    await writeState("running", { maxRestarts: args.maxRestarts });
    const state = await readLoopHeartbeat();
    const heartbeat = state?.heartbeatAt ? Date.parse(state.heartbeatAt) : 0;
    if (!heartbeat || Date.now() - heartbeat > args.staleMs) {
      lastError = `stale loop heartbeat: ${state?.heartbeatAt ?? "missing"}`;
      await writeState("stale-child", { maxRestarts: args.maxRestarts });
      await log(`stale heartbeat; terminating pid=${child.pid}`);
      child.kill("SIGTERM");
    }
  }, Math.min(args.staleMs, 30_000)).unref();
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log("Usage: node scripts/development-supervisor.mjs [--interval-ms N] [--max-cycles N] [--stale-ms N] [--backoff-ms N] [--max-restarts N]");
    return;
  }
  await acquireLock();
  console.log(`KanaAI development supervisor: instance=${instanceId} staleMs=${args.staleMs} maxRestarts=${args.maxRestarts || "unlimited"}`);
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    if (startTimer) clearTimeout(startTimer);
    if (child) child.kill("SIGTERM");
    await writeState("stopping", { maxRestarts: args.maxRestarts });
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  await startChild(args);
  await staleWatch(args);
  await new Promise((resolvePromise) => {
    const poll = setInterval(() => {
      if (stopping) {
        clearInterval(poll);
        resolvePromise();
      }
    }, 250);
  });
  await releaseLock();
  await writeState("stopped", { maxRestarts: args.maxRestarts });
  console.log("Development supervisor stopped.");
}

main().catch(async (error) => {
  await log(`fatal ${error.stack || error.message}`);
  await writeState("failed", { error: error.stack || error.message });
  await releaseLock();
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
