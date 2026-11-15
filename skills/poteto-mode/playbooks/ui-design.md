### UI design / frontend polish

**You own the visual direction. Generate or review, then verify the surface is not AI slop.** 本剧本是 **writing** 技能 Unslop 章节在 UI 层的对应。 它以 **writing** 技能的 Impeccable 章节（`npx impeccable`）作为确定性闸门。

1. Clarify the surface: what page/component, what audience, what the page must communicate. Do **not** over-specify visual style — `npx impeccable` 检测器负责 "don't" 清单; intent handles the "do".
2. Run the **explain** skill (how section) over the existing UI subsystem (framework, component library, design tokens) before generating.
3. Generate or review the surface. Keep changes surgical and re-ground against source for upstream-derived files.
4. 用 **writing** 技能 Impeccable 章节的确定性检测器：
   ```bash
   export DO_NOT_TRACK=1   # avoid the anonymous telemetry record
   npx impeccable detect <path|dir|url>
   ```
   Exit code 2 means findings; 0 means clean. For runtime issues (low contrast, tiny text, failed reveal animations) point it at your dev server URL instead of a file.
5. Fix every flagged tell: drop single-sided color borders (`side-tab`), replace Inter / system fonts (`overused-font`), open up type hierarchy (`flat-type-hierarchy`), drop cream backgrounds (`cream-palette`), tame em-dash density (`em-dash-overuse`, advisory), cut marketing buzzwords. Legitimate brand choices get an ignore: `npx impeccable ignores add-value overused-font Inter --reason "Brand font"`.
6. Re-run `npx impeccable detect` until clean (or only defensible advisories remain). "Inconclusive" or wrong-surface is not a pass.
7. If the design is contested, `interrogate` before shipping.
8. Run **Opening a PR**.

**Reply:** what you built/reviewed, the impeccable findings before/after, what you chose and why, open decisions.

> Note: this playbook only invokes `npx impeccable detect` (pure rules, no LLM). The full `/impeccable` harness skill (PRODUCT.md, DESIGN.md, 24 commands, edit hooks) is harness-specific and intentionally not ported — WorkBuddy drives the gate via the CLI directly.
