#!/usr/bin/env bash
#
# context-probe.sh — measure how much context each Claude Code CLI flag strips
# from a non-interactive session.
#
# Each probe runs one trivial turn ("Reply with only: OK") through the real CLI
# with --output-format json, then reads the token accounting out of the result.
# The prompt is deliberately near-zero tokens, so everything the API charges on
# the way in IS the harness overhead: system prompt, tool schemas, CLAUDE.md,
# skills, plugins and MCP tool definitions.
#
# TRUE CONTEXT SIZE = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
#
# All three must be summed. cache_read_input_tokens is the slice of the prompt
# that was served from a warm prompt cache; it is still part of the context the
# model sees, it was just cheaper. Summing only input+cache_creation (a common
# mistake) silently undercounts by whatever a previous run left warm, and the
# split between cache_creation and cache_read shifts run to run while the total
# stays stable. Compare totals, never the individual columns.
#
# Usage:
#   ./context-probe.sh              # run every probe
#   ./context-probe.sh 1 5 6        # run only those probe ids
#   ./context-probe.sh --list       # show the matrix without spending calls
#
# Env:
#   CLAUDE_BIN   path to the CLI            (default: ~/.local/bin/claude)
#   MODEL        model alias for probes     (default: sonnet)
#   OUTDIR       where result JSON is kept  (default: mktemp -d)
#
# COST WARNING: every probe is a real billed API call against the default
# account. Re-run the whole matrix only after a CLI upgrade.

set -uo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
MODEL="${MODEL:-sonnet}"
PROMPT="Reply with only: OK"

# --- sterile execution environment -------------------------------------------
# The probe must not inherit anything from the session that launched it:
#  - CLAUDE_CONFIG_DIR would point at a fallback/agent profile instead of the
#    primary ~/.claude, measuring the wrong account's plugin set.
#  - CLAUDECODE / CLAUDE_CODE_CHILD_SESSION mark a nested run and can change
#    harness behaviour.
# cwd is an empty temp dir with no CLAUDE.md and no .git in any ancestor, so
# CLAUDE.md auto-discovery and git-status injection have nothing to find.
SCRUB=(
  -u CLAUDE_CONFIG_DIR
  -u CLAUDECODE
  -u CLAUDE_CODE_CHILD_SESSION
  -u CLAUDE_CODE_SESSION_ID
  -u CLAUDE_CODE_ENTRYPOINT
  -u CLAUDE_CODE_EXECPATH
  -u CLAUDE_CODE_BRIDGE_SESSION_ID
  -u CLAUDE_EFFORT
  -u CLAUDE_PID
  -u CLAUDE_JOB_DIR
  -u AI_AGENT
)

OUTDIR="${OUTDIR:-$(mktemp -d -t context-probe-XXXXXX)}"
PROBE_CWD="$(mktemp -d -t probe-cwd-XXXXXX)"
MCP_EMPTY="$OUTDIR/mcp-empty.json"
echo '{"mcpServers":{}}' > "$MCP_EMPTY"
mkdir -p "$OUTDIR"

# --- the matrix ---------------------------------------------------------------
# Probe ids are stable: cite them in results write-ups.
# 1-7 are the levers under test, one at a time then stacked.
# 8-10 follow up on the --bare auth restriction (see results doc).
probe_label() {
  case "$1" in
    1)  echo "baseline (no extra flags)" ;;
    2)  echo "--bare" ;;
    3)  echo "--disable-slash-commands" ;;
    4)  echo '--tools "Bash,Read,Write"' ;;
    5)  echo "--strict-mcp-config --mcp-config <empty>" ;;
    6)  echo "full stack (2+3+4+5)" ;;
    7)  echo "full stack + --system-prompt" ;;
    8)  echo "--safe-mode" ;;
    9)  echo "no-skills + tools + strict-mcp (OAuth-safe stack)" ;;
    10) echo "#9 + --system-prompt" ;;
    11) echo '#10 but --tools "" (no tools at all)' ;;
    *)  echo "?" ;;
  esac
}

# Fills the global PROBE_ARGS array. Flags go AFTER the positional prompt so a
# variadic option (--tools, --mcp-config) can never swallow the prompt itself.
probe_args() {
  PROBE_ARGS=()
  case "$1" in
    1)  ;;
    2)  PROBE_ARGS=(--bare) ;;
    3)  PROBE_ARGS=(--disable-slash-commands) ;;
    4)  PROBE_ARGS=(--tools "Bash,Read,Write") ;;
    5)  PROBE_ARGS=(--strict-mcp-config --mcp-config "$MCP_EMPTY") ;;
    6)  PROBE_ARGS=(--bare --disable-slash-commands --tools "Bash,Read,Write"
                    --strict-mcp-config --mcp-config "$MCP_EMPTY") ;;
    7)  PROBE_ARGS=(--bare --disable-slash-commands --tools "Bash,Read,Write"
                    --strict-mcp-config --mcp-config "$MCP_EMPTY"
                    --system-prompt "You are a minimal assistant.") ;;
    8)  PROBE_ARGS=(--safe-mode) ;;
    9)  PROBE_ARGS=(--disable-slash-commands --tools "Bash,Read,Write"
                    --strict-mcp-config --mcp-config "$MCP_EMPTY") ;;
    10) PROBE_ARGS=(--disable-slash-commands --tools "Bash,Read,Write"
                    --strict-mcp-config --mcp-config "$MCP_EMPTY"
                    --system-prompt "You are a minimal assistant.") ;;
    11) PROBE_ARGS=(--disable-slash-commands --tools ""
                    --strict-mcp-config --mcp-config "$MCP_EMPTY"
                    --system-prompt "You are a minimal assistant.") ;;
  esac
}

ALL_PROBES=(1 2 3 4 5 6 7 8 9 10 11)

if [ "${1:-}" = "--list" ]; then
  for id in "${ALL_PROBES[@]}"; do
    probe_args "$id"
    printf '%2s  %-52s  %s\n' "$id" "$(probe_label "$id")" "${PROBE_ARGS[*]}"
  done
  exit 0
fi

PROBES=("$@")
[ ${#PROBES[@]} -eq 0 ] && PROBES=("${ALL_PROBES[@]}")

echo "CLI:     $($CLAUDE_BIN --version 2>&1)"
echo "model:   $MODEL"
echo "outdir:  $OUTDIR"
echo "cwd:     $PROBE_CWD"
echo

# --- run ----------------------------------------------------------------------
run_probe() {
  local id="$1"
  probe_args "$id"
  local json="$OUTDIR/probe-$id.json"
  local err="$OUTDIR/probe-$id.err"
  local cmd="$OUTDIR/probe-$id.cmd"

  printf 'probe %s: %s ... ' "$id" "$(probe_label "$id")"
  printf '%s -p "%s" --output-format json --model %s %s\n' \
    "$CLAUDE_BIN" "$PROMPT" "$MODEL" "${PROBE_ARGS[*]}" > "$cmd"

  ( cd "$PROBE_CWD" && env "${SCRUB[@]}" "$CLAUDE_BIN" \
      -p "$PROMPT" --output-format json --model "$MODEL" \
      "${PROBE_ARGS[@]}" ) > "$json" 2> "$err"
  local rc=$?
  echo "$rc" > "$OUTDIR/probe-$id.rc"

  if [ $rc -ne 0 ] || ! jq -e . "$json" >/dev/null 2>&1; then
    echo "FAILED (exit $rc)"
    head -c 300 "$err" | sed 's/^/    /'
    echo
  else
    echo "ok  $(jq -r '(.usage.input_tokens + .usage.cache_creation_input_tokens + .usage.cache_read_input_tokens) | tostring + " tokens"' "$json")"
  fi
}

for id in "${PROBES[@]}"; do
  run_probe "$id"
done

# --- table --------------------------------------------------------------------
# Baseline for the delta column is probe 1, read from disk so a partial re-run
# (./context-probe.sh 6 7) still reports deltas against an earlier full run.
baseline=""
if [ -f "$OUTDIR/probe-1.json" ] && jq -e . "$OUTDIR/probe-1.json" >/dev/null 2>&1; then
  baseline=$(jq -r '.usage.input_tokens + .usage.cache_creation_input_tokens + .usage.cache_read_input_tokens' "$OUTDIR/probe-1.json")
fi

echo
echo "| # | flag combo | input | cache_creation | cache_read | **context** | delta vs baseline | out | exit |"
echo "|---|---|---|---|---|---|---|---|---|"
for id in "${ALL_PROBES[@]}"; do
  json="$OUTDIR/probe-$id.json"
  [ -f "$json" ] || continue
  rc=$(cat "$OUTDIR/probe-$id.rc" 2>/dev/null || echo "?")
  label=$(probe_label "$id")
  if ! jq -e . "$json" >/dev/null 2>&1; then
    printf '| %s | %s | — | — | — | **ERROR** | — | — | %s |\n' "$id" "$label" "$rc"
    continue
  fi
  read -r i cc cr o < <(jq -r '[.usage.input_tokens, .usage.cache_creation_input_tokens, .usage.cache_read_input_tokens, .usage.output_tokens] | @tsv' "$json")
  total=$(( i + cc + cr ))
  if [ -n "$baseline" ] && [ "$baseline" -gt 0 ]; then
    d=$(( total - baseline ))
    pct=$(awk -v d="$d" -v b="$baseline" 'BEGIN{printf "%+.1f", 100*d/b}')
    delta=$(printf '%+d (%s%%)' "$d" "$pct")
  else
    delta="—"
  fi
  printf '| %s | %s | %s | %s | %s | **%s** | %s | %s | %s |\n' \
    "$id" "$label" "$i" "$cc" "$cr" "$total" "$delta" "$o" "$rc"
done

echo
echo "Raw result JSON kept in $OUTDIR"
