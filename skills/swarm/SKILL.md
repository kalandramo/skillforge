---
name: "swarm"
version: "1.0.0"
display_name: "并行扇出覆盖（Swarm）"
description: "并行多切片展开：覆盖矩阵切分、同题竞速、夹击验证与探索分区，避免单线盲点。当用户说「分头查」「并行覆盖一下」「多切片扫一遍」「赛马比一比」「swarm」时使用。同一产物要多个候选用 arena。"
user-invocable: true
---

# Swarm

## Start

Open a todolist with one entry per phase before launching anything.

1. Frame
2. Fan out
3. Aggregate
4. Report

## Phase A: Frame

1. State the done predicate and the artifact or report the swarm must return.
2. Choose the shape. Partition into slices, race N workers on identical briefs, or mix both. For a race or mixed shape, declare `first pass`, `rank all`, or `best-of` before spawning.
3. Pick the worker model. WorkBuddy, ZCode and Qoder all choose the subagent model and effort themselves, so leave `model` unset and let every worker run on the host default. If the host exposes a `model` parameter, use one slug it accepts, and name each arm's model up front for a model race. If it rejects a slug, fall back to its default and say so.
4. Give each worker its own writable output when it writes. When workers verify or measure commits, each brief names the exact SHAs. A measurement brief also names the method (sample count, what one sample is, order). The worker records both in its result.

## Phase B: Fan out

Spawn all N workers in one message with `subagent_type: general-purpose`, `run_in_background: true` where the host supports it, and the step 3 model, left unset.

When a worker must start from a non-default pushed branch, pass `cloud_base_branch`.

**Host notes.** WorkBuddy spawns with `Agent`; ZCode and Qoder spawn with `Task`. None of the three runs workers on a cloud VM, so every worker runs locally: give each one its own worktree or output path. Keep the brief. Drop parameters your tool doesn't have. If the host has no subagent tool, run the workers yourself, one after another.

Every brief stands alone. Include the goal, scope, exact slice or race arm, how to verify, and what to report. Reports use `PASS`, `ISSUES`, or `BLOCKED` with evidence. A worker that can prove a defect reports `ISSUES` and lists every issue it can prove, not only the first.

If a worker drops out, proceed with N-1 and note it.

## Phase C: Aggregate

Read the terminal results. Drop a result that does not record the SHAs and method its brief names, and respawn that worker once. After a second miss, record a gap. A gap does not count as a pass. For coverage, every required slice needs a result. For a race, apply the selection rule declared up front. Use first pass, rank all, or best-of. Do not paste raw worker dumps.

## Phase D: Report

Return one consolidated in-chat report with a result table, issue one-liners, gaps or dropouts, and the race rule when used.
