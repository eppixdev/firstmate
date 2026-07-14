#!/usr/bin/env bash
# tests/fm-codex-lock-identity.test.sh - managed Codex sandbox identity and
# liveness classification for the per-home firstmate session lock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-codex-lock-identity.mjs"
LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-lock-identity-tests)
STATE_DB="$TMP_ROOT/state.sqlite"
LOGS_DB="$TMP_ROOT/logs.sqlite"
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
CURRENT_THREAD=019f5e42-c487-76c1-b079-9fafa203bcea
PEER_THREAD=019f5e42-c59b-74b0-bea6-729499fbd397
EXITED_THREAD=019f53eb-dd2a-7090-a519-2f254aa3d892
ARCHIVED_THREAD=019f53eb-ddfe-75f1-94ac-cfe863b62c5f
UNKNOWN_THREAD=019f5962-8192-7aa2-bd2b-027847998880
RESUMED_THREAD=019f5962-8192-7aa2-bd2b-027847998881
EXITED_RESUMED_THREAD=019f5962-8192-7aa2-bd2b-027847998882
PROCESS_A=pid:56297:aa837eb9-c72c-4607-a8f8-912fb4e58add
PROCESS_B=pid:86213:340d61e5-c357-4276-afb6-8e679aabb284

mkdir -p "$HOME_DIR/state" "$FAKEBIN"
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '/bin/zsh\n' ;;
  *"args="*) printf 'zsh\n' ;;
  *"ppid="*) printf '1\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/ps"

FM_CODEX_STATE_DB="$STATE_DB" FM_CODEX_LOGS_DB="$LOGS_DB" node <<'NODE'
const { DatabaseSync } = require("node:sqlite");
const state = new DatabaseSync(process.env.FM_CODEX_STATE_DB);
state.exec("CREATE TABLE threads (id TEXT PRIMARY KEY, archived INTEGER NOT NULL)");
const putThread = state.prepare("INSERT INTO threads (id, archived) VALUES (?, ?)");
putThread.run("019f5e42-c487-76c1-b079-9fafa203bcea", 0);
putThread.run("019f5e42-c59b-74b0-bea6-729499fbd397", 0);
putThread.run("019f53eb-dd2a-7090-a519-2f254aa3d892", 0);
putThread.run("019f53eb-ddfe-75f1-94ac-cfe863b62c5f", 1);
putThread.run("019f5962-8192-7aa2-bd2b-027847998880", 0);
putThread.run("019f5962-8192-7aa2-bd2b-027847998881", 0);
putThread.run("019f5962-8192-7aa2-bd2b-027847998882", 0);

const logs = new DatabaseSync(process.env.FM_CODEX_LOGS_DB);
logs.exec("CREATE TABLE logs (id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT, process_uuid TEXT, feedback_log_body TEXT)");
const putLog = logs.prepare("INSERT INTO logs (thread_id, process_uuid, feedback_log_body) VALUES (?, ?, ?)");
putLog.run("019f5e42-c487-76c1-b079-9fafa203bcea", "pid:56297:aa837eb9-c72c-4607-a8f8-912fb4e58add", "current turn");
putLog.run("019f5e42-c59b-74b0-bea6-729499fbd397", "pid:56297:aa837eb9-c72c-4607-a8f8-912fb4e58add", "idle peer");
putLog.run("019f53eb-dd2a-7090-a519-2f254aa3d892", "pid:86213:340d61e5-c357-4276-afb6-8e679aabb284", "session_loop: Agent loop exited");
putLog.run("019f53eb-ddfe-75f1-94ac-cfe863b62c5f", "pid:86213:340d61e5-c357-4276-afb6-8e679aabb284", "archived thread");
putLog.run("019f5962-8192-7aa2-bd2b-027847998880", "pid:86213:340d61e5-c357-4276-afb6-8e679aabb284", "idle unknown process");
putLog.run("019f5962-8192-7aa2-bd2b-027847998881", "pid:86213:340d61e5-c357-4276-afb6-8e679aabb284", "resumed turn");
putLog.run("019f5962-8192-7aa2-bd2b-027847998882", "pid:56297:aa837eb9-c72c-4607-a8f8-912fb4e58add", "resumed session: Agent loop exited");
NODE

helper() {
  CODEX_THREAD_ID="$CURRENT_THREAD" FM_CODEX_STATE_DB="$STATE_DB" FM_CODEX_LOGS_DB="$LOGS_DB" "$HELPER" "$@"
}

helper_for_thread() {
  CODEX_THREAD_ID="$1" FM_CODEX_STATE_DB="$STATE_DB" FM_CODEX_LOGS_DB="$LOGS_DB" "$HELPER" "${@:2}"
}

token=$(helper current)
expected="codex-thread:$CURRENT_THREAD:$PROCESS_A"
[ "$token" = "$expected" ] || fail "Codex current identity mismatch: $token"
pass "Codex lock identity combines the stable thread id with its runtime process uuid"

[ "$(helper classify "$token")" = live ] || fail "current Codex thread was not live"
[ "$(helper classify "codex-thread:$PEER_THREAD:$PROCESS_A")" = live ] || fail "same-process peer thread was not live"
[ "$(helper classify "codex-thread:$EXITED_THREAD:$PROCESS_B")" = dead ] || fail "exited Codex thread was not dead"
[ "$(helper classify "codex-thread:$ARCHIVED_THREAD:$PROCESS_B")" = dead ] || fail "archived Codex thread was not dead"
[ "$(helper classify "codex-thread:$UNKNOWN_THREAD:$PROCESS_B")" = unknown ] || fail "unprovable foreign process was not unknown"
[ "$(helper classify "codex-thread:$EXITED_RESUMED_THREAD:$PROCESS_B")" = dead ] \
  || fail "exited resumed peer was treated as live because it shared the current runtime process"
[ "$(helper classify malformed)" = unknown ] || fail "malformed token was not unknown"
[ "$(helper_for_thread "$RESUMED_THREAD" classify "codex-thread:$RESUMED_THREAD:$PROCESS_A")" = dead ] \
  || fail "same Codex thread's previous runtime process was not dead"
pass "Codex lock liveness distinguishes live, dead, and unprovable holders"

PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" CODEX_THREAD_ID="$CURRENT_THREAD" \
  FM_CODEX_STATE_DB="$STATE_DB" FM_CODEX_LOGS_DB="$LOGS_DB" "$LOCK" >/dev/null \
  || fail "managed Codex identity did not acquire an empty lock"
[ "$(cat "$HOME_DIR/state/.lock")" = "$expected" ] || fail "managed Codex token was not persisted"

status=0
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" CODEX_THREAD_ID="$PEER_THREAD" \
  FM_CODEX_STATE_DB="$STATE_DB" FM_CODEX_LOGS_DB="$LOGS_DB" "$LOCK" >/dev/null 2>&1 || status=$?
expect_code 1 "$status" "same-process peer must observe live contention"
pass "a second live Codex thread cannot steal the first thread's lock"

FM_CODEX_STATE_DB="$STATE_DB" node -e \
  'const {DatabaseSync}=require("node:sqlite"); const d=new DatabaseSync(process.env.FM_CODEX_STATE_DB); d.prepare("UPDATE threads SET archived=1 WHERE id=?").run(process.argv[1]);' \
  "$CURRENT_THREAD"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" CODEX_THREAD_ID="$PEER_THREAD" \
  FM_CODEX_STATE_DB="$STATE_DB" FM_CODEX_LOGS_DB="$LOGS_DB" "$LOCK" >/dev/null \
  || fail "archived holder did not yield its stale lock"
expected_peer="codex-thread:$PEER_THREAD:$PROCESS_A"
[ "$(cat "$HOME_DIR/state/.lock")" = "$expected_peer" ] || fail "peer did not replace the archived holder token"
pass "an archived Codex holder yields its stale lock safely"

printf '%s\n' "codex-thread:$RESUMED_THREAD:$PROCESS_A" > "$HOME_DIR/state/.lock"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" CODEX_THREAD_ID="$RESUMED_THREAD" \
  FM_CODEX_STATE_DB="$STATE_DB" FM_CODEX_LOGS_DB="$LOGS_DB" "$LOCK" >/dev/null \
  || fail "resumed Codex thread did not replace its previous runtime process token"
expected_resumed="codex-thread:$RESUMED_THREAD:$PROCESS_B"
[ "$(cat "$HOME_DIR/state/.lock")" = "$expected_resumed" ] \
  || fail "resumed Codex thread did not persist its current runtime process token"
pass "a resumed Codex thread replaces its stale runtime process lock"

legacy_holder=424242
printf '%s\n' "$legacy_holder" > "$HOME_DIR/state/.lock"
status=0
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" CODEX_THREAD_ID="$CURRENT_THREAD" \
  FM_CODEX_STATE_DB="$STATE_DB" FM_CODEX_LOGS_DB="$LOGS_DB" "$LOCK" >/dev/null 2>&1 || status=$?
expect_code 2 "$status" "managed Codex must not classify an invisible legacy PID as dead"
[ "$(cat "$HOME_DIR/state/.lock")" = "$legacy_holder" ] \
  || fail "managed Codex replaced an unprovable legacy PID lock"
pass "managed Codex preserves an invisible legacy PID lock as indeterminate"
