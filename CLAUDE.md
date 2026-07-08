# resurrect.wezterm

## Reading the repo

Use the `## Project structure` map in AGENTS.md to go straight to the relevant file.
Only open additional files when the structure map and what you have already read leave
you without enough context to act. Stop reading once you can act — the plugin is small
(~1,400 LOC across ten files) but reading it all on every task wastes context.

## Commit messages

Follow Conventional Commits matching the existing history: `type(scope): summary`.
Common types: `feat`, `fix`, `chore`, `docs`, `refactor`.
Scope is usually the module — `(state_manager)`, `(encryption)`, `(fuzzy_loader)`,
`(ci)`. Keep the summary imperative and focused on one logical change.

## Pull requests

Before opening or updating a PR, confirm:

- `stylua --check plugin/` reports no formatting issues.
- `luacheck plugin/` reports zero warnings.
- `lua-language-server --check plugin/` reports no errors.
- All `opts` parameters that are documented as optional have a nil guard.
- No `os.execute()` calls with concatenated user-controlled strings in the diff.
- The diff is focused — no unrelated reformatting or churn.

Do not create a PR unless explicitly asked.

## Documentation

After completing a code change that alters the public API, module structure, or CI
pipeline, update the relevant sections of AGENTS.md (`## Project structure`,
`## Build and test`) to match. Do not update documentation for internal-only changes
without explicit approval.

If a change alters restore or workspace-switching behavior relative to the original
project, update the "Behavioral changes" table in `docs/migrating_from_upstream.md`
to match — that table is the one place the fork's divergences are enumerated, and it
silently rots if a new one isn't added there.
