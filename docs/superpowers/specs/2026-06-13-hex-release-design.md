# Prepare E2bEx for a Hex.pm release (0.1.0) — design

**Status:** approved
**Date:** 2026-06-13
**Branch:** `chore/hex-release` (off `main`).

## Goal

Make `e2b_ex` publishable to [Hex.pm](https://hex.pm) as `0.1.0` so it can be
pulled into other projects via `{:e2b_ex, "~> 0.1.0"}`. Scope is **essentials
only**: package metadata, an MIT `LICENSE`, and README polish — enough to publish
cleanly. The actual `mix hex.publish` is run by the maintainer (it needs Hex
auth); this work gets the repo to one-command-ready.

## Release scope

Release `main` **as-is**: the published `0.1.0` covers **Sandboxes, Templates,
Tags, Volumes, and running commands inside a sandbox** (Commands: `run`,
streaming, background execution). The **PTY/terminal** feature (built on the
unmerged `feat/pty` / PR #1) and the **Filesystem** API are **not** in this
release — they ship in later releases. The README states this.

Decisions (from brainstorming): Hex.pm package; release main as-is (no PTY);
MIT license; essentials only.

## Changes

### 1. `mix.exs` — add publishable package metadata

Add a `description/0` and `package/0`, wire them into `project/0`, and add source
links so HexDocs links back to GitHub. Keep `version: "0.1.0"`.

```elixir
def project do
  [
    app: :e2b_ex,
    version: "0.1.0",
    elixir: "~> 1.18",
    elixirc_paths: elixirc_paths(Mix.env()),
    start_permanent: Mix.env() == :prod,
    deps: deps(),
    name: "E2bEx",
    description: description(),
    package: package(),
    source_url: "https://github.com/col/e2b_ex",
    docs: [
      main: "E2bEx",
      extras: ["README.md"],
      source_ref: "v0.1.0"
    ]
  ]
end

defp description do
  "An Elixir client for the E2B sandbox platform"
end

defp package do
  [
    licenses: ["MIT"],
    links: %{"GitHub" => "https://github.com/col/e2b_ex"},
    maintainers: ["Colin Harris"]
  ]
end
```

**Files shipped in the package:** rely on Hex's **default `files` list**
(`lib`, `mix.exs`, `README*`, `LICENSE*`, `.formatter.exs`, `CHANGELOG*`, …). The
default **excludes** `docs/superpowers/` (specs/plans), `test/`, and the ~large
`openapi.yml`, so none of those ship. No explicit `files:` key is needed.

The Hex **package name** defaults to the app name → `e2b_ex`. This name must be
free on Hex.pm; `mix hex.publish` reports a conflict if not (cannot be checked
offline).

### 2. `LICENSE` — MIT

A standard MIT license at the repo root: `Copyright (c) 2026 Colin Harris`. Hex
detects it automatically and matches it to the `licenses: ["MIT"]` metadata.

### 3. README polish

- **Intro line:** change *"covering Sandboxes, Templates, and Tags"* to
  *"covering Sandboxes, Templates, Tags, Volumes, and running commands inside a
  sandbox."*
- **Badges:** add Hex.pm version + HexDocs badges at the top (standard for a
  published library):
  ```markdown
  [![Hex.pm](https://img.shields.io/hexpm/v/e2b_ex.svg)](https://hex.pm/packages/e2b_ex)
  [![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/e2b_ex)
  ```
- **Roadmap line:** replace the existing *"PTY support is planned for a later
  phase."* with one noting **both** upcoming features:
  *"PTY (interactive terminals) and Filesystem (read/write/list/watch files)
  support are planned for later releases."*
- **Installation:** already shows `{:e2b_ex, "~> 0.1.0"}` — no change.

## Verification & publish flow

- **Automated (no Hex auth needed):**
  - `mix hex.build` — builds the package tarball and validates metadata,
    description, and license. This is the primary release-readiness check; it
    fails/warns if `description`/`licenses` are missing or malformed.
  - `mix test` stays green; `mix compile --warnings-as-errors` stays clean.
  - `mix docs` builds the docs locally without error (confirms ExDoc config +
    `source_ref`).
- **Maintainer-run (needs Hex account; NOT part of this change):**
  - `mix hex.publish` — publishes the package **and** docs to HexDocs.
  - `git tag v0.1.0 && git push --tags` — tag the release.

## Error handling / risks

- **Name taken on Hex:** only surfaces at `mix hex.publish` time; out of our
  control. Documented as a pre-publish note.
- **`mix hex.build` not available:** `hex` is bundled with Mix; if `mix
  hex.build` is unavailable the archive can be installed with `mix local.hex`.
  The plan notes this fallback.

## Out of scope

- CHANGELOG.md and a CI (GitHub Actions) workflow.
- The PTY/terminal feature (PR #1) and the Filesystem API — later releases.
- The deferred dedup refactors.
- Running `mix hex.publish` itself (maintainer action, needs auth).

## Files

- Modify: `mix.exs` (add `description/0`, `package/0`, `source_url`, docs
  `source_ref`).
- Create: `LICENSE` (MIT).
- Modify: `README.md` (intro feature list, badges, roadmap line).
