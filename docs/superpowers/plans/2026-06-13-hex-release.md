# Hex.pm Release (0.1.0) Prep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `e2b_ex` publishable to Hex.pm as `0.1.0` (package metadata, MIT LICENSE, README polish), verified locally with `mix hex.build`.

**Architecture:** Pure release-prep — no library code changes. Add a `package`/`description` to `mix.exs`, a root `LICENSE`, and polish the README to match the 0.1.0 surface (Sandboxes, Templates, Tags, Volumes, Commands; PTY + Filesystem noted as later releases). The maintainer runs `mix hex.publish` afterward (needs Hex auth); this gets the repo one-command-ready.

**Tech Stack:** Elixir/Mix, Hex (`mix hex.build`/`mix hex.publish`), ExDoc.

**Reference spec:** `docs/superpowers/specs/2026-06-13-hex-release-design.md`

---

## File Structure

- **Modify** `mix.exs` — add `description/0`, `package/0`, `source_url`, and docs `source_ref`.
- **Create** `LICENSE` — MIT, `Copyright (c) 2026 Colin Harris`.
- **Modify** `README.md` — intro feature list, Hex/HexDocs badges, consolidate the roadmap line (PTY + Filesystem are later releases).

### Notes for the implementer

- This repo is **hand-formatted** and does NOT use `mix format`. Do NOT run `mix format`; match the surrounding style using the exact code below.
- These are config/doc changes, not TDD code — each task's "verification" is a `mix` command (e.g. `mix hex.build` validates package metadata), not a failing test.
- `mix hex.build` needs the bundled `hex` archive. If it's missing, run `mix local.hex --force` first. It builds a local tarball and validates metadata **without** network or Hex auth.
- Do NOT run `mix hex.publish` — that's the maintainer's step (needs their Hex account). The final task only documents it.

---

## Task 1: `mix.exs` — package metadata

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add `description`, `package`, `source_url`, and docs `source_ref` to `project/0`**

Replace the existing `project/0` function:

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
      docs: [
        main: "E2bEx",
        extras: ["README.md"]
      ]
    ]
  end
```

with:

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
```

- [ ] **Step 2: Add the `description/0` and `package/0` helpers**

Immediately after the `application/0` function (before `defp deps do`), add:

```elixir
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

- [ ] **Step 3: Verify it compiles cleanly**

Run: `mix compile --warnings-as-errors`
Expected: clean (metadata-only change; no warnings).

- [ ] **Step 4: Commit**

```bash
git add mix.exs
git commit -m "chore(release): add Hex package metadata to mix.exs"
```

---

## Task 2: `LICENSE` (MIT)

**Files:**
- Create: `LICENSE`

- [ ] **Step 1: Create the MIT license file**

Create `LICENSE` with exactly this content:

```
MIT License

Copyright (c) 2026 Colin Harris

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Verify**

Run: `head -3 LICENSE`
Expected: shows `MIT License` and the `Copyright (c) 2026 Colin Harris` line.

- [ ] **Step 3: Commit**

```bash
git add LICENSE
git commit -m "chore(release): add MIT LICENSE"
```

---

## Task 3: README polish

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add badges and expand the intro feature list**

Replace the top of the file:

```markdown
# E2bEx

An Elixir client for the [E2B](https://e2b.dev) API, covering Sandboxes,
Templates, and Tags. Built on [`Req`](https://hex.pm/packages/req).
```

with:

```markdown
# E2bEx

[![Hex.pm](https://img.shields.io/hexpm/v/e2b_ex.svg)](https://hex.pm/packages/e2b_ex)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/e2b_ex)

An Elixir client for the [E2B](https://e2b.dev) API, covering Sandboxes,
Templates, Tags, Volumes, and running commands inside a sandbox. Built on
[`Req`](https://hex.pm/packages/req).
```

- [ ] **Step 2: Remove the inline PTY-planned clause in the streaming section**

Replace:

```markdown
Background execution and reconnecting are available via `start/4`/`connect/4`;
PTY is planned for a later phase.
```

with:

```markdown
Background execution and reconnecting are available via `start/4`/`connect/4`.
```

- [ ] **Step 3: Consolidate the roadmap line to mention PTY + Filesystem**

Replace the standalone line:

```markdown
PTY support is planned for a later phase.
```

with:

```markdown
PTY (interactive terminals) and Filesystem (read/write/list/watch files) support
are planned for later releases.
```

- [ ] **Step 4: Verify**

Run: `grep -n "Volumes, and running commands\|hexpm/v/e2b_ex\|planned for later releases" README.md`
Expected: three matches — the expanded intro line, the Hex badge, and the consolidated roadmap line.

Run: `grep -c "planned for a later phase" README.md`
Expected: `0` (both old phrasings are gone).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(release): polish README for 0.1.0 (badges, feature list, roadmap)"
```

---

## Task 4: Release-readiness verification

No code changes — confirm the repo is publish-ready and record the maintainer's publish steps.

- [ ] **Step 1: Ensure the `hex` archive is available**

Run: `mix hex.info 2>/dev/null || mix local.hex --force`
Expected: prints Hex info, or installs the archive.

- [ ] **Step 2: Full test + strict compile**

Run: `mix test`
Expected: all tests pass, 0 failures.

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Build the package tarball (validates metadata, no auth/network)**

Run: `mix hex.build`
Expected: succeeds and prints the package contents. Confirm in the output that:
- the package builds with name `e2b_ex` version `0.1.0`,
- `lib/`, `mix.exs`, `README.md`, and `LICENSE` are included,
- `docs/`, `test/`, and `openapi.yml` are **NOT** included,
- there are **no warnings** about a missing description or license.

If `mix hex.build` warns that no files match the license or that the description
is missing, the metadata from Task 1 / the file from Task 2 is wrong — fix before
proceeding.

- [ ] **Step 4: Build the docs locally**

Run: `mix docs`
Expected: builds `doc/index.html` without error (confirms ExDoc config +
`source_ref: "v0.1.0"`).

- [ ] **Step 5: Record (do NOT run) the maintainer publish steps**

These are run by the maintainer after merge (they need Hex auth) — do not run them
here; just confirm they are documented in the final report:

```bash
# one-time: authenticate (if not already)
mix hex.user auth

# publish the package AND docs to HexDocs:
mix hex.publish

# tag the release:
git tag v0.1.0
git push --tags
```

Note: `e2b_ex` must be an unclaimed name on Hex.pm — `mix hex.publish` reports a
conflict if it is taken (cannot be verified offline).

- [ ] **Step 6: Commit any cleanup**

`mix docs` writes to `doc/` and `mix hex.build` writes a `*.tar` — both should be
git-ignored or removed; do NOT commit them. Verify:

Run: `git status --short`
Expected: clean (no `doc/`, no `*.tar` staged). If `doc/` or `e2b_ex-0.1.0.tar`
appear as untracked, remove them (`rm -rf doc e2b_ex-*.tar`) — they are build
artifacts, not source.

---

## Final Review

After all tasks, dispatch a final reviewer over the whole change, then use `superpowers:finishing-a-development-branch`.

Sanity checklist before merge:
- [ ] `mix hex.build` succeeds with a clean package (`lib`/`mix.exs`/`README`/`LICENSE` in; `docs`/`test`/`openapi.yml` out; no metadata warnings).
- [ ] `mix.exs` has `description`, `package` (MIT license, GitHub link, maintainer), `source_url`, docs `source_ref`.
- [ ] `LICENSE` is MIT with the correct copyright holder/year.
- [ ] README: badges present, intro lists Volumes + commands, no "planned for a later phase" wording, roadmap notes PTY + Filesystem.
- [ ] `mix test` green; `mix compile --warnings-as-errors` clean.
- [ ] No build artifacts (`doc/`, `*.tar`) committed.
- [ ] No library (`lib/`) behavior changed.
```
