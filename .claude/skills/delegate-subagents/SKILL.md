---
name: delegate-subagents
description: How to delegate MacMiniMixer work to subagents cheaply — pick the cheapest model that can do the job, write tight prompts that point at a shared brief instead of repeating it, and keep reports short. Use before every Agent tool call in this repo, and whenever the user asks for work "with subagents".
---

# Delegating to subagents in MacMiniMixer

Every subagent starts cold and pays for its own requests. Spend Opus only where the
work is genuinely hard; give every agent a short, specific prompt; ask for short reports.

## 1. Should this be a subagent at all?

Do it yourself (no agent) when:
- it takes ≤ 3 tool calls (one grep, one read, one small edit);
- it is reviewing a diff, cherry-picking, pushing, or reading CI status;
- you already hold the context in this conversation.

Reuse instead of respawning: a follow-up on the same area goes to the existing agent via
`SendMessage` — it keeps its context; a new agent re-reads everything.

Run agents in parallel only when their file sets are disjoint (see §4).

## 2. Pick the model (pass `model:` or use a typed agent)

| Work | Model | Typed agent |
|---|---|---|
| Find call sites / conformers, list files, count tests, check docs for stale strings, summarize a CI log | `haiku` | `code-scout` |
| Docs / README / CHANGELOG updates from a given list of facts | `sonnet` | `docs-writer` |
| Mechanical Swift edits that follow an existing pattern: renames, accessibility modifiers, adding tests that mirror existing ones, pbxproj entry edits, workflow/script changes | `sonnet` | `swift-editor` |
| Product Real start/stop/lane/queue logic, Core Audio / Process Tap code, concurrency (`@MainActor`, `Sendable`, actors, continuations), cross-coordinator refactors, design plans for risky areas | `opus` | `swift-implementer` (or the built-in `Plan` agent for read-only design) |

When unsure between two tiers, pick the cheaper one and give it a tighter prompt; escalate
only if it reports it is stuck. Never use Opus for search or docs.

## 3. Write a tight prompt

Every prompt starts with one line: **"Read `.claude/skills/delegate-subagents/project-brief.md` first."**
That file holds the repo constraints (no Swift toolchain in the cloud, guardrails, pbxproj rule,
worktree reset, commit trailer, report format). Do **not** paste those constraints again.

Then give only:
1. **Base:** the commit/branch to reset to (worktree agents start from an old commit).
2. **Goal:** one or two sentences — the behavior change, not the history.
3. **Where:** exact files and function names (and approximate lines) you already found. Don't
   make the agent rediscover what you know.
4. **Rules specific to this task:** what must not change; what another parallel agent owns.
5. **Done when:** the tests to add/update by name or behavior.
6. **Report:** "≤ 15 lines: SHA, files, behavior, tests, compile risks." (Long reports cost you context.)

Long design notes → write them to a scratchpad file once and pass the path; never paste them
into several prompts.

Target size: ≤ 40 lines for `opus` tasks, ≤ 20 lines for `sonnet`, ≤ 10 for `haiku`.

## 4. Parallel work without conflicts

- Assign each agent a file set; list the files the *other* agent owns as off-limits.
- Shared test fakes (`MacMiniMixerTests/ProductRealControlCoordinatorTests.swift`) and
  `MixerViewModel.swift` are conflict hot spots — tell parallel agents to add new members rather
  than rewrite existing ones, or run those tasks sequentially.
- Always use `isolation: "worktree"` for agents that edit files; you cherry-pick their commits.

## 5. After the agent returns

- Review its diff yourself (`git show <sha> -- MacMiniMixer/`) before cherry-picking; check
  semantic conflicts with anything merged meanwhile (protocol conformers, fakes, guards).
- Verify with CI or, when CI cannot run, hand the user the local `xcodebuild test` command.
- **Never block on CI.** GitHub Actions for this repo can be out of macOS minutes: a job that
  ends within seconds with no steps and `runner_id: 0` is an infra/billing failure, not a code
  failure. Re-run it at most once; if it fails the same way, stop waiting, tell the user CI is
  unavailable, and give the local test + install command. Subagents never wait on or poll CI.
- Remove its worktree and branch when merged.
