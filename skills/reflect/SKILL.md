---
name: "reflect"
version: "1.0.0"
display_name: "复盘沉淀（Reflect）"
description: "把一段长任务的经验沉淀成可复用的教训或新技能，多个评审角色（分歧、判断、综合、工具）协同产出。当用户说「复盘一下」「总结经验」「沉淀成技能」「这次学到什么」「reflect」时使用。短任务不需要。"
user-invocable: true
---

# Reflect

Mine the current conversation for durable learnings, then route them into skill edits.

Invoke when the user says "reflect" or "/reflect". Skip when the conversation is trivial, off-topic, or already covered by an existing skill the parent followed correctly. One-offs are not learnings.

## 1. Locate the active transcript

Before fanning out, find this conversation's transcript in the active workspace's session directory. Do not glob across every project's directory. That crosses workspace boundaries and reads private chats from unrelated projects.

Where the transcript lives depends on the host:

- **WorkBuddy:** `~/.workbuddy/projects/<slug>/<session-id>.jsonl`, where `<slug>` is the workspace path with every character that isn't a letter or digit turned into "-".

  ```bash
  ls -t "$HOME/.workbuddy/projects/<slug>"/*.jsonl 2>/dev/null | head -10
  ```

  For each candidate, read the first JSONL line and take the file whose `message.content[0].text` contains the conversation's opening user prompt.
- **Qoder:** `~/.qoder-cn/projects/<slug>/<session-id>.jsonl` (`~/.qoder/projects/<slug>/` for Qoder international), same `<slug>` rule, same way to confirm a candidate.
- **Codex:** `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`. Codex files sessions by start date, not by project, so the directory tells you nothing about the workspace — read the first `session_meta` line and keep only files whose `payload.cwd` is this workspace, then confirm by the opening user prompt:

  ```bash
  grep -l "\"cwd\":\"$PWD\"" "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -10
  ```

- **ZCode:** sessions live in a local database, not in per-project files. There is no transcript to read, so pass a tight digest of the session instead.

Take the newest candidates first. If none matches the opening prompt, pass a tight digest of the session instead.

## 2. Spawn three reviewers in parallel

One message, three subagent calls (WorkBuddy `Agent`; ZCode and Qoder `Task`; Codex `spawn_agent` with its `worker` or `default` agent), `subagent_type: general-purpose`, agent mode (`readonly: false`). Reviewers need MCP access to look up the tickets, chat threads, and observability traces the transcript references, and readonly strips MCPs.

**Host notes.** Keep the prompt. Drop parameters your tool doesn't have. If the host has no subagent tool, run each role yourself, one after another.

**Models.** WorkBuddy, ZCode, Qoder and Codex all choose the subagent model and effort themselves, so leave `model` unset: there is no model-config file to read. If a host exposes a model parameter, keep the judgment seats on its strongest setting. If it rejects a slug, use the default and say so.

| Lens | Seat | Prompt template |
|---|---|---|
| Judgment | the host's strongest judgment model | `references/judgment-reviewer.md` |
| Tooling | the host's default model | `references/tooling-reviewer.md` |
| Divergent | the host's strongest judgment model | `references/divergent-reviewer.md` |

Pass each template verbatim, substituting the transcript path or digest where marked. Reviewers return findings in the subagent's response body.

## 3. Synthesize

One subagent call, `subagent_type: general-purpose`, model left to the host on its strongest setting, agent mode (`readonly: false`). It spot-verifies citations through MCP, and readonly strips MCPs. Pass `references/synthesizer.md` verbatim, with each reviewer's full output inlined where marked. It returns an Accepted / Rejected / Backlog list.

## 4. Structural enforcement check

Move any Accepted item that a lint rule, script, metadata flag, or runtime check would enforce more reliably to Backlog. See the **encode-lessons-in-structure** entry in the **principles** skill.

## 5. Apply

Present the synthesizer's full Accepted / Rejected / Backlog output and wait for explicit approval before applying any Accepted edit. The user picks the subset and may redirect routings. Skill changes affect every future agent in the org. Do not auto-apply.

File each Backlog item to your team's devex or backlog tracker without waiting. Only the Accepted list waits for approval.

Never edit a skill under `plugins/cache/`. Before approval, show its destination: `.workbuddy/skills/<skill>/` or `~/.workbuddy/skills/<skill>/` in WorkBuddy, `.zcode/skills/<skill>/` or `~/.zcode/skills/<skill>/` in ZCode, `.qoder/skills/<skill>/` or `~/.qoder-cn/skills/<skill>/` in Qoder, `.agents/skills/<skill>/` or `~/.agents/skills/<skill>/` in Codex. After approval, copy the skill folder there and edit the copy. Never open a PR or push.

Follow each approved row's Routing exactly:

- Trivial existing-skill edit (a one-line bullet, a tightened sentence, a stale fact corrected): the parent does it directly.
- Substantive existing-skill edit (a new section, a new pattern table, more than ~10 lines): hand to your harness's skill-authoring skill and run its draft / test / iterate loop. That is the **skill-creator** skill in WorkBuddy and the bundled `$skill-creator` system skill in Codex; ZCode and Qoder have none, so follow the Agent Skills format at agentskills.io by hand. "`create-skill`" below means whichever of these you use.
- `tune description: <skill path>` (the skill exists but didn't trigger when it should have): hand to `create-skill` and run its description-optimization loop.
- `new skill via create-skill: <kebab-name>`: hand creation to `create-skill`. Do not invent the shape ad hoc.

If your environment ships a SKILL.md validator, run it on every touched skill before declaring done.

## 6. Summarize for the user

Short list, no preamble:

- Edits applied: `<skill path>`. What changed, one line each.
- New skills created: `<skill path>`. One line each (rare).
- Backlog filed to the devex tracker: `<issue title>` (`<tags>`). One line each.
- Dropped: one line per rejected finding + reason from the synthesizer.
