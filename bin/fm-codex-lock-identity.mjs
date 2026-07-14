#!/usr/bin/env node
// Resolve and classify Codex Desktop thread identities for fm-lock.sh when
// the managed sandbox hides the harness process behind its PID namespace.
//
// Usage:
//   fm-codex-lock-identity.mjs current
//     Prints codex-thread:<thread-id>:<process-uuid> for the current thread.
//   fm-codex-lock-identity.mjs classify <token>
//     Prints live, dead, or unknown for a previously recorded token.
//
// The helper reads Codex's local runtime databases without modifying them.
// FM_CODEX_STATE_DB and FM_CODEX_LOGS_DB are test-only path overrides.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { DatabaseSync } from "node:sqlite";

const THREAD_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PROCESS_RE = /^pid:[1-9][0-9]*:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN_RE = /^codex-thread:([0-9a-f-]{36}):(pid:[1-9][0-9]*:[0-9a-f-]{36})$/i;

const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");

function latestVersionedDatabase(prefix, override) {
  if (override) return override;
  const candidates = fs.readdirSync(codexHome)
    .map((name) => ({ name, match: new RegExp(`^${prefix}_([0-9]+)\\.sqlite$`).exec(name) }))
    .filter(({ match }) => match)
    .sort((a, b) => Number(b.match[1]) - Number(a.match[1]));
  if (candidates.length === 0) throw new Error(`missing ${prefix} runtime database`);
  return path.join(codexHome, candidates[0].name);
}

const statePath = latestVersionedDatabase("state", process.env.FM_CODEX_STATE_DB);
const logsPath = latestVersionedDatabase("logs", process.env.FM_CODEX_LOGS_DB);

function openReadOnly(databasePath) {
  return new DatabaseSync(databasePath, { readOnly: true });
}

function latestLog(database, threadId) {
  return database.prepare(`
    SELECT process_uuid, feedback_log_body
    FROM logs
    WHERE thread_id = ? AND process_uuid IS NOT NULL
    ORDER BY id DESC
    LIMIT 1
  `).get(threadId);
}

function processFor(database, threadId) {
  const row = latestLog(database, threadId);
  if (!row || !PROCESS_RE.test(row.process_uuid || "")) return null;
  return row.process_uuid;
}

function threadArchived(database, threadId) {
  const row = database.prepare("SELECT archived FROM threads WHERE id = ?").get(threadId);
  return row?.archived === 1;
}

function agentLoopExited(row) {
  return typeof row?.feedback_log_body === "string"
    && /Agent loop exited\s*$/.test(row.feedback_log_body);
}

function currentToken(logs) {
  const threadId = process.env.CODEX_THREAD_ID || "";
  if (!THREAD_RE.test(threadId)) return null;
  const processUuid = processFor(logs, threadId);
  if (!processUuid) return null;
  return `codex-thread:${threadId}:${processUuid}`;
}

function classify(token, state, logs) {
  const match = TOKEN_RE.exec(token);
  if (!match || !THREAD_RE.test(match[1]) || !PROCESS_RE.test(match[2])) return "unknown";
  const [, holderThread, holderProcess] = match;
  const currentThread = process.env.CODEX_THREAD_ID || "";

  if (THREAD_RE.test(currentThread) && holderThread === currentThread) return "live";
  if (threadArchived(state, holderThread)) return "dead";

  const holderLog = latestLog(logs, holderThread);
  if (holderLog?.process_uuid === holderProcess && agentLoopExited(holderLog)) return "dead";

  const currentProcess = THREAD_RE.test(currentThread) ? processFor(logs, currentThread) : null;
  if (currentProcess && holderLog?.process_uuid === currentProcess) return "live";
  if (currentProcess && holderProcess === currentProcess) return "live";

  if (holderLog && agentLoopExited(holderLog)) return "dead";
  return "unknown";
}

function main() {
  const [command, token] = process.argv.slice(2);
  if (command !== "current" && command !== "classify") process.exit(2);

  try {
    const logs = openReadOnly(logsPath);
    if (command === "current") {
      const value = currentToken(logs);
      if (!value) process.exit(2);
      process.stdout.write(`${value}\n`);
      return;
    }

    const state = openReadOnly(statePath);
    process.stdout.write(`${classify(token || "", state, logs)}\n`);
  } catch {
    process.exit(2);
  }
}

main();
