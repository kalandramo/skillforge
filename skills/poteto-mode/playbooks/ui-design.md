### UI design / frontend polish

**You own the visual direction. Generate or review, then verify the surface is not AI slop.** This playbook is the UI-layer counterpart to `unslop`. It leans on the `impeccable` skill as a deterministic gate.

1. Clarify the surface: what page/component, what audience, what the page must communicate. Do **not** over-specify visual style — impeccable handles the "don't" list; intent handles the "do".
2. `how` over the existing UI subsystem (framework, component library, design tokens) before generating.
3. Generate or review the surface. Keep changes surgical and re-ground against source for upstream-derived files.
4. Gate with the `impeccable` skill — run the deterministic detector:
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
