# Clean_the_floor Agent Rules

This repository uses a feature registry to keep gameplay changes traceable.

## Required workflow

1. Read `PROJECT_START_HERE.md` and `docs/features/README.md`.
2. Locate the affected feature with `scripts\feature-impact.cmd <path-or-contract>`.
3. Read every returned feature page before editing code or Studio objects.
4. State which feature invariants and regression checks the change affects.
5. Keep runtime authority in source code. Update feature documentation whenever player behavior, Remote contracts, snapshot fields, persistent fields, Studio paths, ownership, or reset rules change.
6. Run `scripts\verify-project.cmd` before finishing.

## Source and Studio boundaries

- Edit production Luau only under `src`; synchronize it through Rojo.
- Do not write production scripts in Roblox Studio.
- Studio object paths and types are owned by `docs/05_STUDIO_OBJECT_CONTRACT.md`.
- Feature pages explain why those objects exist and how they participate in a flow.
- Do not infer unverified Studio structure. Mark it `待Studio核验` until the target Place is inspected.

## Documentation authority

- Runtime values, identifiers, and validation logic: source code.
- Current feature behavior and change impact: `docs/features/*.md`.
- Exact Studio hierarchy: `docs/05_STUDIO_OBJECT_CONTRACT.md`.
- Full playtest procedure: `docs/09_CHECKPOINT_B_VALIDATION.md`.
- Completed test evidence: `docs/10_CHECKPOINT_B_RUN_LOG.md`.
- Files under `docs/archive` are historical and must not be used as current behavior.

If two active documents disagree, stop copying the conflict. Verify the source or target Studio, fix the owning feature page, and leave one canonical fact.
