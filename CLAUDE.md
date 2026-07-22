# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A regression-guard test suite for the Flow Gradle plugin's
`vaadinBuildFrontend` task and its build-cache wiring. Each subproject
is a deliberately minimal Vaadin Flow application that exercises a
different archive shape (`jar`, `war`, `bootJar`, `shadowJar`,
user-defined `Jar`, custom `frontendOutputDirectory`). The suite is
**not** a normal codebase — the Java/resources under each subproject
exist only so the scripted scenarios have something to edit, and the
real assertions live in `scripts/`.

## Architecture in one paragraph

`scripts/run-project.sh` drives one subproject through the same
fixed scenario set (A–H in cold mode, plus opt-in relocatability
scenario R; single FROM-CACHE assertion in warm mode);
`scripts/run-suite.sh` is a thin wrapper that runs
`run-project.sh` over every subproject (canonical list in its
`ALL_PROJECTS` array) and prints a PASS/FAIL summary. It looks up
project-specific values (build task,
archive path, in-archive bundle prefix) from a `case` statement keyed
on the project dir name — so adding a new subproject means adding a
matching `case` branch alongside the project's `build.gradle`, plus a
new entry in the matrix in `.github/workflows/build-cache.yml`.
Assertions about Gradle task outcomes go through
`scripts/assert-task-outcome.sh`, which parses `--console=plain` logs
for `> Task :foo` lines and matches the suffix (`FROM-CACHE`,
`UP-TO-DATE`, none = SUCCESS). The archive content check is a
`unzip -l | grep META-INF/VAADIN/webapp/` on the produced
jar/war.

## Two modes: source vs published

The suite runs in two modes, selected by whether `run-project.sh` gets
the `--vaadin-platform` flag. Both modes take the same positional
arguments — `<project> <version>` — and the flag only changes how the
trailing `<version>` is interpreted:

- **Source mode** (default): `<version>` is a Flow version. Builds the
  root-level projects (`plain-jar/`, `war/`, …), which apply the
  `com.vaadin.flow` plugin and depend on `com.vaadin:flow`, both at a
  `-PflowVersion` resolved from a **locally-installed** Flow
  (mavenLocal) — what `build-cache.yml` sets up by building Flow from a
  ref.
- **Published mode** (`--vaadin-platform`): `<version>` is a Vaadin
  *platform* version. Builds the mirror projects under `platform/`,
  which apply the Vaadin platform plugin (`id 'com.vaadin'`, versioned
  by that platform version) and resolve `com.vaadin:flow` from Maven
  Central / the vaadin-prereleases repo — no mavenLocal.
  `run-project.sh` routes `project_dir` to `platform/<project>` and
  passes `-PvaadinVersion` plus a `-PflowVersion` that is **derived**
  from the platform version (or set by `--flow-version=<v>`), not
  assumed equal to it. Vaadin 25+ only.

Each `platform/<project>` is a real `build.gradle` + `settings.gradle`
mirroring the root project's non-Vaadin config, but its `src/` and
Gradle wrapper (`gradle/`, `gradlew`, `gradlew.bat`) are **symlinks**
back to the root project — one source of truth, so scenario edits
(B/C/D) behave identically. The per-project `case` in `run-project.sh`
(build task, archive glob, bundle prefix) is keyed on the basename and
is shared by both modes; only the directory prefix differs.

The Vaadin platform version and the Flow version are **not** aligned at
the patch level (e.g. Vaadin `25.2.3` ships Flow `25.2.4`).
`scripts/resolve-flow-version.sh <vaadin-version>` derives the Flow
version by reading `<flow.version>` from the
`com.vaadin:vaadin-gradle-plugin:<vaadin-version>` POM (Central first,
then vaadin-prereleases; SNAPSHOTs resolved via the version-level
`maven-metadata.xml`). Never key the plugin or the `com.vaadin:flow`
dependency off the Vaadin version directly.

## Running locally

The Flow Gradle plugin under test must already be installed to
`~/.m2/repository` — this repo does **not** build Flow. From a Flow
checkout:

```bash
./mvnw -B -DskipTests -am -pl flow-plugins/flow-gradle-plugin install
FLOW_VERSION=$(cd /path/to/flow && ./mvnw -q help:evaluate -Dexpression=project.version -DforceStdout)
```

Then:

```bash
# Cold: wipes ~/.gradle/caches/build-cache-1, runs scenarios A–H + R.
bash scripts/run-project.sh --cache=cold plain-jar "$FLOW_VERSION"

# Warm (default): leaves cache alone, asserts clean build → FROM-CACHE.
bash scripts/run-project.sh plain-jar "$FLOW_VERSION"
```

Published mode needs no Flow checkout — just a published Vaadin version
(25+); the Flow version is derived:

```bash
# Cold, against a published release (Flow version derived from Vaadin).
bash scripts/run-project.sh --cache=cold --vaadin-platform plain-jar 25.2.3

# Whole suite, published mode.
bash scripts/run-suite.sh --vaadin-platform 25.2.3
```

Warm mode requires the cache to already be populated (cold run first,
or restored Actions cache in CI). The runner's per-project parameters
(build task, archive path, in-archive prefix) live in the `case`
statement at `scripts/run-project.sh:176`.

## Scenarios (cold mode)

Each scenario is destructive but registers an undo via
`register_cleanup` **before** the destructive step. Cold-mode scenarios
are wrapped by `scenario_begin`/`scenario_end`: `scenario_begin` records
the cleanup-stack depth (and wipes `build/`), `scenario_end` flushes that
scenario's cleanups immediately (LIFO), so edits never leak between
scenarios — that is what lets D and F both edit `HelloView.java`. The
EXIT trap → `flush_cleanups` is still the abort safety net.

Every scenario also asserts the **produced bundle content**, not only
the task outcome, via a signature over the archived
`META-INF/VAADIN/config/stats.json` (which embeds `frontendHashes` +
`packageJsonHash` + `bundleImports`). Scenario A captures the baseline
(`capture_baseline_signature`); hits assert `assert_signature_same`,
frontend-changing misses assert `assert_signature_differs` plus an
`assert_bundle_file_contains` for the staged marker. This catches a false
hit that serves a *stale* bundle — invisible to an outcome-only check.

Two non-obvious details make the content check reliable (both learned the
hard way — see `bundle_signature` and `scenario_begin`):

- **Why stats.json, not the `.js` chunks.** The bundler tree-shakes an
  unused module out of the compiled output, so an added `@JsModule`
  (scenario F) can leave the webapp `.js` chunks byte-identical; only
  stats.json's `bundleImports` records the new import. So the signature
  hashes stats.json, not the produced bundle files.
- **Normalization.** Flow writes stats.json pretty-printed when it
  *compiles* the bundle but compact (with a `"pre-compiled":true` flag)
  when it *reuses* the packaged `src/main/bundles/prod.bundle`.
  `bundle_signature` strips all whitespace and drops that flag so
  compile-vs-reuse formatting is not mistaken for a bundle change.
- **`prod.bundle` clean.** `scenario_begin` deletes `src/main/bundles`
  and `src/main/dev-bundle` before every scenario. Flow reuses an
  existing compatible `prod.bundle`, so a bundle compiled by an earlier
  scenario would be served unchanged even after a frontend edit — masking
  F/G/H. A fresh CI checkout never has this file; removing it makes local
  runs match CI. It is **not** a Gradle cache input, so FROM-CACHE
  scenarios are unaffected (the task is restored from Gradle's cache, not
  recompiled). Cold mode also clears `src/main/frontend/generated` once
  before scenario A for a full reset.

Cache-hit guards (FROM-CACHE, signature unchanged):

- **A**: build → `rm -rf build/` → build. Expect SUCCESS then FROM-CACHE.
  Captures the baseline bundle signature.
- **B**: Add `src/test/java/com/example/AddedTest.java` → build. FROM-CACHE.
- **C**: Append to `src/main/resources/messages.properties` → build. FROM-CACHE.
  - Uses `messages.properties` specifically because it is **not**
    declared as an input of `vaadinBuildFrontend`.
    `application.properties` is declared as `@InputFile` with content
    sensitivity, so editing it correctly invalidates the cache and is
    not a useful negative case.
- **E**: Append a comment **after the final `}`** of `HelloView.java` →
  build. FROM-CACHE. The trailing comment shifts no code line numbers, so
  javac emits byte-identical bytecode; guards against a key that keys on
  source text/timestamps rather than normalized compiled output.
- **R**: Relocatability. **Opt-in, off by default** — enable with
  `--relocatability` (run-project.sh and run-suite.sh) or
  `RUN_RELOCATABILITY=1`. Copy the project to a fresh absolute path (via
  `tar --dereference`, excluding `node_modules`/`build`/`.gradle` **and**
  the generated frontend surface — the whole `src/main/frontend` tree,
  `src/main/bundles`, `src/main/dev-bundle`) and build there against the
  **same** shared cache → FROM-CACHE. Guards against absolute paths
  leaking into the cache key — the reason a *shared* cache exists.
  `--dereference` resolves the platform mirrors' top-level symlinks so the
  copy is a fully independent tree. The generated-frontend excludes make
  the copy match a fresh git checkout (all those paths are gitignored):
  copying them in instead plants pre-existing task outputs at a checkout
  with no `.gradle` history, which Gradle flags as `OVERLAPPING_OUTPUTS`
  (on `src/main/frontend/index.html`) and marks `:vaadinBuildFrontend`
  non-cacheable — a *false* failure that would mask the real bug. Disabled
  by default because on the current plugin `:vaadinBuildFrontend`
  re-executes at a new path (every other task relocates, and same-path
  `rm -rf build/` still restores FROM-CACHE), so its key is
  path-dependent. Root cause pinned via `-Dorg.gradle.caching.debug` across
  two pristine checkouts: six `@Input` **value** properties on
  `VaadinBuildFrontendTask` hold absolute directory paths hashed verbatim
  into the key (`frontendDirectory`, `frontendOutputDirectory`,
  `javaSourceFolder`, `javaResourceFolder`, `npmFolder`,
  `resourcesOutputDirectory`); the real content inputs relocate fine
  (`IGNORED_PATH`/`CLASSPATH`/`RELATIVE_PATH`). R is a hard guard that
  flips green once the plugin makes those path-insensitive — a pending
  investigation, not an accepted behaviour.

Cache-miss guards (NOT FROM-CACHE):

- **D**: Edit `HelloView.java` heading literal → build. NOT_FROM_CACHE
  (guards against a key that ignores main-classpath bytecode). The
  heading is server-side, so the bundle is unchanged → signature *same*.
- **F**: Create `src/main/frontend/marker-widget.js` and add
  `@JsModule("./marker-widget.js")` to the view → build. NOT_FROM_CACHE;
  signature differs; `marker-widget` staged in stats.json.
- **G**: Edit `src/main/frontend/index.html` (the app-shell template, a
  declared frontend input) → build. NOT_FROM_CACHE; signature differs;
  the marker reaches the built `webapp/index.html`.
- **H**: Inject the `fixtures/demo-addon` jar via
  `--init-script scripts/addon-init.gradle` (`-PdemoAddonJar=…`) → build.
  NOT_FROM_CACHE; signature differs; `demo-addon-marker` staged. The
  add-on ships a `@Route` view (Flow discovers routes classpath-wide)
  whose `@JsModule` stages the module with **no** app source change, so
  this isolates "a dependency's frontend is a cache input" from any
  bytecode change. `run-project.sh` builds the fixture jar first
  (`build_addon_jar`, incremental).

## CI workflow

There are two workflows, both `workflow_dispatch` only:
`build-cache.yml` (source mode, below) and
`build-cache-published.yml` (published mode). The published one drops
the `build-flow` job entirely — instead a `resolve-version` job derives
the Flow version from the `vaadin_version` input (or takes a
`flow_version` override), then the cold/warm matrices build the
`platform/` projects. Its cold/warm cache keys are scoped to
`(matrix.project, vaadin-version, flow-version, run_id, run_attempt)`,
and failure log artifacts come from `platform/<project>/*.log`.
Everything else (matrix, warm gating, `fail-on-cache-miss`) mirrors the
source workflow described next.

`.github/workflows/build-cache.yml` is `workflow_dispatch` only.
Inputs `flow_repo` (default `vaadin/flow`) and `flow_ref` (default
`main`) let it run against any branch/tag/SHA, including PR branches
on forks. A third optional input, `flow_version`, takes a **published**
Flow version instead: when set, the `build-flow` job is skipped, the
`flow-m2` download/restore steps are skipped, and the scenario jobs
resolve Flow straight from Central / vaadin-prereleases (the cache-key
discriminator becomes the version instead of the built SHA). This still
exercises the `com.vaadin.flow` plugin — it is the source-mode analogue
of `build-cache-published.yml`'s platform-plugin path. Three jobs:

1. `build-flow` installs the plugin to `~/.m2/repository`, then
   uploads only `com/vaadin/**` as `flow-m2.tgz` to avoid shipping
   Maven Central noise to the matrix jobs.
2. `scenarios-cold` (matrix over all subprojects) restores the
   artifact, runs `--cache=cold`, and saves
   `~/.gradle/caches/build-cache-1` under a key scoped to
   `(matrix.project, flow-sha, run_id, run_attempt)`. Including
   `run_attempt` matters — Actions cache writes are write-once, so
   without it a "Re-run all jobs" would no-op against the prior
   attempt's cache.
3. `scenarios-warm` (matrix) restores the matching cold cache on a
   fresh runner and runs `--cache=warm`. `fail-on-cache-miss: true`
   on the restore step is deliberate: a silent pass on a cold cache
   would defeat the matrix. The job is gated on `build-flow` success,
   **not** all-cold success, so warm entries whose cold counterpart
   failed fail loudly (cache miss) instead of being silently skipped.

To validate a Flow PR: dispatch with `flow_ref=<pr-branch>`, then
re-run with `flow_ref=<pre-fix-SHA>` to confirm the suite actually
catches what the PR fixes. If both pass, the suite isn't exercising
what we think.

## Adding a new test project

1. Create `new-project/` with its own `build.gradle`, `settings.gradle`,
   Gradle wrapper, and the same `src/main/java/com/example/` layout
   (`Application.java`, `HelloView.java`, `PlainService.java`) and
   `src/main/resources/{application,messages}.properties` as the
   existing subprojects — scenarios B–G edit those exact paths
   (`HelloView.java` for D/E/F, `messages.properties` for C,
   `src/main/frontend/index.html` for G — the last is generated by the
   first build, so nothing to commit). Scenarios H (shared
   `fixtures/demo-addon` jar via init script) and R (relocatability, a
   generic tree copy) need no per-project setup.
2. Add a `case` branch in `scripts/run-project.sh` setting
   `BUILD_TASK`, `ARCHIVE_GLOB`, and `BUNDLE_PREFIX`. `BUNDLE_PREFIX`
   is the prefix inside the archive where the Flow plugin stages the
   bundle (`""` for jars, `WEB-INF/classes/` for wars,
   `BOOT-INF/classes/` for Spring Boot).
3. Add `new-project` to both matrix lists in
   `.github/workflows/build-cache.yml` (cold and warm), and to the
   `ALL_PROJECTS` array in `scripts/run-suite.sh`.
4. Add the published-mode mirror `platform/new-project/`: a real
   `build.gradle` (same non-Vaadin config, but `id 'com.vaadin'` in
   place of `com.vaadin.flow`, no `mavenLocal()`, and
   `com.vaadin:flow:${flowVersion}` resolved from Central/prereleases)
   and `settings.gradle`, plus **symlinks** `src -> ../../new-project/src`,
   `gradle -> ../../new-project/gradle`, `gradlew`, `gradlew.bat`. Then
   add `new-project` to both matrix lists in
   `.github/workflows/build-cache-published.yml`.
5. Update the project table and the layout tree in `README.md`.

## Conventions worth knowing

- Subprojects intentionally do **not** set a `version` — the
  `tasks.withType(Jar).configureEach { archiveVersion = '' }` block
  drops the `-unspecified` suffix Gradle would otherwise append, so
  `ARCHIVE_GLOB` paths in `run-project.sh` stay stable.
- `settings.gradle` in every subproject pins the plugin via
  `resolutionStrategy.eachPlugin` reading `-PflowVersion`, so the same
  `build.gradle` works against any locally-installed Flow snapshot.
- The Gradle wrapper is committed in every subproject; the runner
  prefers it but honours `GRADLE_BIN` overrides.
- Per-scenario logs (`scenario-*.log`, `warm.log`) are written into
  the subproject dir and are gitignored. CI uploads them as artifacts
  on failure only.

## Project-specific guidance from `~/.claude/CLAUDE.md`

- Bug fixes: write a failing test first, confirm it fails, then fix.
- Never commit without asking permission.
- Commit format: `type: subject` (`fix:`, `feat:`, `chore:`,
  `refactor:`; `!` for breaking). Wrap `@`-prefixed words and class
  names in backticks. Never list yourself as co-author.
- Temp files belong in `/tmp/claude/`, not in this project tree.
