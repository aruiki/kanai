#!/usr/bin/env node

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dashboardRoot = resolve(root, "dev-dashboard");
const stateDir = resolve(root, ".development-loop");
const port = Number(process.env.KANAI_DEVELOPMENT_DASHBOARD_PORT ?? 8090);
const host = process.env.KANAI_DEVELOPMENT_DASHBOARD_HOST ?? "127.0.0.1";
const execFileAsync = promisify(execFile);

async function readText(path, fallback = "") {
  try { return await readFile(path, "utf8"); } catch { return fallback; }
}

async function readJson(path) {
  try { return JSON.parse(await readText(path, "{}")); } catch { return {}; }
}

async function tail(path, lines = 20) {
  const text = await readText(path, "");
  return text.split(/\r?\n/).filter(Boolean).slice(-lines);
}

function json(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "content-length": Buffer.byteLength(body) });
  response.end(body);
}

async function readCodeRevision() {
  try {
    const { stdout } = await execFileAsync("git", ["log", "-1", "--format=%h%x09%s%x09%cI"], { cwd: root });
    const [short, subject, committedAt] = stdout.trim().split("\t");
    return { short, subject, committedAt };
  } catch {
    return { short: "--", subject: "取得不可", committedAt: null };
  }
}

async function statusPayload() {
  const [loop, supervisor, log, codeRevision] = await Promise.all([
    readJson(resolve(stateDir, "state.json")),
    readJson(resolve(stateDir, "supervisor-state.json")),
    tail(resolve(stateDir, "supervisor.log"), 30),
    readCodeRevision(),
  ]);
  const results = Array.isArray(loop.results) ? loop.results : [];
  return {
    now: new Date().toISOString(),
    codeRevision,
    progress: { technical: 75, niche: 40, publicBeta: 0 },
    loop: {
      status: loop.status ?? "unknown",
      cycle: loop.cycle ?? null,
      heartbeatAt: loop.heartbeatAt ?? null,
      results: results.map((result) => ({ id: result.id, ok: result.ok, durationMs: result.durationMs })),
    },
    supervisor: {
      status: supervisor.status ?? "unknown",
      pid: supervisor.pid ?? null,
      restarts: supervisor.restarts ?? 0,
    },
    focus: {
      title: "Windows x64 TSFを実機でInstallingする",
      copy: "Mozc TIPのbuildは完了。次にTSF registrationとNotepadの入力receiptを接続します。",
      blocker: "ITfInputProcessorProfiles::Registerが非管理者sessionでEFAILを返す。",
    },
    log: { lines: log },
  };
}

const mime = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
};

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
    if (url.pathname === "/api/status") {
      json(response, 200, await statusPayload());
      return;
    }
    const requested = url.pathname === "/" ? "/index.html" : url.pathname;
    const file = resolve(dashboardRoot, `.${requested}`);
    if (!file.startsWith(dashboardRoot)) throw new Error("invalid path");
    const fileStat = await stat(file);
    if (!fileStat.isFile()) throw new Error("not a file");
    const body = await readFile(file);
    response.writeHead(200, { "content-type": mime[file.slice(file.lastIndexOf("."))] ?? "application/octet-stream", "cache-control": "no-store" });
    response.end(body);
  } catch {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not found");
  }
});

server.listen(port, host, () => {
  console.log(`KanaAI development dashboard: http://${host}:${port}/`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => server.close(() => process.exit(0)));
}
