# Context probe results — which CLI flags actually shrink a session

Measured 2026-08-07 against **Claude Code 2.1.224**, model `sonnet`, on the primary
`~/.claude` account (OAuth subscription, 17 plugins installed).

Reproduce with [`context-probe.sh`](context-probe.sh). Re-run the whole matrix after a
CLI upgrade — every number here is version-specific.

## Method

Each probe runs one turn of `Reply with only: OK` through the real CLI with
`--output-format json`. The prompt is ~19 tokens, so essentially everything the API
charges on the way in is harness overhead: system prompt, tool schemas, skills
catalogue, plugin and MCP tool definitions.

Probes run from an empty temp cwd with **no CLAUDE.md and no `.git` in any ancestor**,
with `CLAUDE_CONFIG_DIR` and the nested-session markers (`CLAUDECODE`,
`CLAUDE_CODE_CHILD_SESSION`, …) scrubbed from the environment.

**Context size = `input_tokens` + `cache_creation_input_tokens` + `cache_read_input_tokens`.**

All three must be summed. `cache_read_input_tokens` is the part of the prompt served
from a warm cache — still context the model reads, just cheaper. Summing only
`input + cache_creation` undercounts by whatever a previous run left warm (24,047
tokens in the baseline probe here), and the split between the two columns moves run to
run while the total stays put. Compare totals only.

## Results

| # | flag combo | input | cache_creation | cache_read | **context** | delta vs baseline | cost | exit |
|---|---|---|---|---|---|---|---|---|
| 1 | baseline (no extra flags) | 2 | 16180 | 24047 | **40,229** | — | $0.1044 | 0 |
| 2 | `--bare` | — | — | — | **ERROR** | — | $0 | 1 |
| 3 | `--disable-slash-commands` | 2 | 10113 | 23424 | **33,539** | −6,690 (−16.6%) | $0.0678 | 0 |
| 4 | `--tools "Bash,Read,Write"` | 2 | 116733 | 0 | **116,735** | **+76,506 (+190.2%)** | $0.7005 | 0 |
| 5 | `--strict-mcp-config --mcp-config <empty>` | 2 | 13130 | 24047 | **37,179** | −3,050 (−7.6%) | $0.0861 | 0 |
| 6 | full stack (2+3+4+5) | — | — | — | **ERROR** | — | $0 | 1 |
| 7 | full stack + `--system-prompt` | — | — | — | **ERROR** | — | $0 | 1 |
| 8 | `--safe-mode` | 2 | 4476 | 24047 | **28,525** | −11,704 (−29.1%) | $0.0347 | 0 |
| 9 | `--disable-slash-commands --tools "Bash,Read,Write" --strict-mcp-config --mcp-config <empty>` | 2 | 14410 | 0 | **14,412** | −25,817 (−64.2%) | $0.0865 | 0 |
| 10 | #9 + `--system-prompt "You are a minimal assistant."` | 2 | 5929 | 0 | **5,931** | −34,298 (−85.3%) | $0.0356 | 0 |
| 11 | #10 but `--tools ""` (no tools at all) | 181 | 0 | 0 | **181** | −40,048 (−99.6%) | $0.0006 | 0 |

Probes 2, 6 and 7 all failed the same way — see below. Probes 8–11 replace them as the
follow-ups the results demanded.

## What each lever actually does

### `--bare` is unusable on this account

All three probes containing `--bare` exited 1 with:

```
Not logged in · Please run /login
```

This is by design, and `--help` says so: under `--bare`, "Anthropic auth is strictly
`ANTHROPIC_API_KEY` or `apiKeyHelper` via `--settings` (OAuth and keychain are never
read)". Beatrice authenticates through OAuth subscriptions — the whole
`CLAUDE_FALLBACK_CONFIG_DIR` chain is OAuth credential files — so **`--bare` cannot be
used on any of her run paths** without moving her to an API key and paying per token.

It costs nothing to find out: the failure is instant, before any API call.

### `--tools` on its own is a trap that triples the context

This is the headline surprise. Restricting to three tools made the context **2.9x
bigger** — 116,735 tokens, $0.70 for one "OK", a single API call (verified:
`usage.iterations` has exactly one entry, so this is one real prompt, not summed
retries).

The cause is tool deferral. Normally the harness defers plugin/MCP tool schemas: only
their *names* are in context, and a `ToolSearch` tool fetches a schema on demand.
`--tools "Bash,Read,Write"` removes `ToolSearch` from the tool set, so deferral is no
longer possible and **every MCP tool schema gets inlined instead**.

Measured cost of the same MCP tool surface both ways:

| MCP tool definitions | tokens |
|---|---|
| deferred (names only, baseline) | ~3,050 |
| inlined (`--tools` without `--strict-mcp-config`) | ~95,600 |

A **31x** difference. `--tools` is only a win when paired with `--strict-mcp-config
--mcp-config <empty>`, which removes the MCP servers so there is nothing left to
inline. Compare probe 4 (116,735) with probe 9 (14,412): same `--tools`, and the only
difference is that the MCP servers are gone.

### The levers that work

| lever | saves | notes |
|---|---|---|
| `--strict-mcp-config --mcp-config <empty>` | 3,050 | small alone, but it is the **precondition** that makes `--tools` safe |
| `--disable-slash-commands` | 6,690 | the skills catalogue; disables all skills including `/screenshot` |
| `--safe-mode` | 11,704 | strips CLAUDE.md, skills, plugins, hooks, MCP, custom agents in one flag — and unlike `--bare`, **auth works normally** |
| `--tools "…"` (with empty MCP) | ~16,000 | trims the built-in tool set; catastrophic without empty MCP |
| `--system-prompt "…"` | 8,481 | replaces the default system prompt |

### Derived composition of the 40,229-token baseline

Backed out of the probe deltas:

| component | tokens |
|---|---|
| floor (minimal system prompt + the 19-token user turn) | 181 |
| default system prompt (over a minimal one) | ~8,481 |
| full built-in tool set | ~21,827 |
| skills catalogue | 6,690 |
| plugin/MCP tool names (deferred) | 3,050 |

The built-in tool schemas are the single biggest line item — over half the baseline.
Three tools (`Bash,Read,Write`) cost 5,750 of that, so roughly **1,900 tokens per
built-in tool** on average.

## Recommended invocations

Both assume an empty MCP config file:

```sh
printf '%s' '{"mcpServers":{}}' > ~/.config/deskcrab/empty-mcp.json
```

### (a) Interactive / wake profile — **14,412 tokens** (−64% vs baseline)

Keeps the default system prompt (so built-in tool-use guidance survives) and a working
tool set, drops skills and MCP:

```sh
claude -p "$PROMPT" --output-format json \
  --strict-mcp-config --mcp-config ~/.config/deskcrab/empty-mcp.json \
  --disable-slash-commands \
  --tools "Bash,Read,Write"
```

Adjust for what she actually needs — budget **~1,900 tokens per added built-in tool**.
Two knobs to weigh:

- Dropping `--disable-slash-commands` costs **+6,690** and buys the skills back
  (`/screenshot` and friends). If she needs skills, that is the price.
- `--strict-mcp-config` is **not optional** here. Without it, `--tools` inlines every
  MCP schema and the context goes to 116k.

### (b) One-question classifier profile — **181 tokens** (−99.6% vs baseline)

No tools, no skills, no MCP, own system prompt:

```sh
claude -p "$QUESTION" --output-format json \
  --strict-mcp-config --mcp-config ~/.config/deskcrab/empty-mcp.json \
  --disable-slash-commands \
  --tools "" \
  --system-prompt "You are a minimal assistant."
```

`--tools ""` disables all tools, which is what makes this profile collapse to almost
nothing: **222x smaller than baseline, $0.0006 versus $0.1044 per call**. Anything that
only needs one text answer and no tool use — classification, routing, wake triage,
yes/no gating — should run this way.

## Caveats

- **No CLAUDE.md was in scope for any probe.** Beatrice runs from `~/Beatrice`, whose
  `CLAUDE.md` is 1,511 bytes (~400 tokens); add that to profile (a). `--safe-mode`
  would suppress it, which is probably not wanted — it is her house context.
- **`--system-prompt` replaces the default system prompt outright.** Profile (b) is
  fine with that. For profile (a), replacing it also discards the built-in tool-use
  instructions, so prefer `--append-system-prompt` if her persona needs to sit on top
  of working tool behaviour.
- **These are per-turn floor sizes**, measured on turn one. Conversation history stacks
  on top.
- `--exclude-dynamic-system-prompt-sections` was **not** probed: per `--help` it *moves*
  cwd/env/git sections into the first user message to improve cross-user cache reuse
  rather than removing them, so it is a cache-hit-rate lever, not a size lever.
- The 12-invocation budget for this measurement was not exhausted — 11 were spent, 1
  unused.
