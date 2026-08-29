# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A regression-guard test suite for the Flow Gradle plugin's
`vaadinBuildFrontend` task and its build-cache wiring. Each subproject
is a deliberately minimal Vaadin Flow application that exercises a
different archive shape (`jar`, `war`, `bootJar`, `shadowJar`,
user-defined `Jar`, custom `frontendOutputDirectory`) — or, in
`multimodule-jar`, a different *build* shape: two modules where the
Vaadin one depends on the other. The suite is
**not** a normal codebase — the Java/resources under each subproject
exist only so the scripted scenarios have something to edit, and the
real assertions live in `scripts/`.

## Architecture in one paragraph

`scripts/run-project.sh` drives one subproject through the same
fixed scenario set (A–I plus relocatability scenario R in cold mode;
single FROM-CACHE assertion in warm mode). Cold mode runs that set once
per **configuration-cache pass** (`--cc=off|on|both`, default both): the
configuration cache is an execution mode that changes *when* task inputs
are computed and therefore what lands in the build-cache key, so the CC
pass re-runs the same scenarios, adds an assertion about the fate of
Gradle's entry, and appends two CC-only scenarios (S and CC-FRESH).
Per-project opt-out via `CC_COMPATIBLE=0`.
`scripts/run-suite.sh` is a thin wrapper that runs
`run-project.sh` over every subproject (canonical list in its
`ALL_PROJECTS` array) and prints a PASS/FAIL summary. It looks up
project-specific values (build task, archive path, in-archive bundle
prefix, and — for multi-module projects — the module path prefix
`MODULE_DIR`, the asserted task path `VBF_TASK`, the `BUILD_DIRS` to wipe
and the `AUX_TASKS` to build) from a `case` statement keyed
on the project dir name — so adding a new subproject means adding a
matching `case` branch alongside the project's `build.gradle`, plus a
new entry in the matrix in `.github/workflows/build-cache.yml`.
Assertions about Gradle task outcomes go through
`scripts/assert-task-outcome.sh`, which parses `--console=plain` logs
for `> Task :foo` lines and matches the suffix (`FROM-CACHE`,
`UP-TO-DATE`, none = SUCCESS); its configuration-cache counterpart is
`scripts/assert-cc.sh`, which parses the same logs for the fate of
Gradle's CC entry (`STORED`/`REUSED`/`UPDATED`/`NOT_REUSED`/`NO_PROBLEMS`)
and carries the Gradle 9.3 message reference. Both are standalone so they
can be run against a log downloaded from a failed CI run. The archive
content check is a
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
# Cold: wipes ~/.gradle/caches/build-cache-1, runs scenarios A–I + R.
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
(build task, archive path, in-archive prefix, module prefix, task path)
live in the `case` statement at `scripts/run-project.sh:316`.

## Multi-module: `multimodule-jar`

The one project with more than one Gradle module: `:lib` (plain `java`)
and `:web` (`java` + `application` + `com.vaadin.flow`) with
`implementation project(':lib')`. That single dependency is the point —
it puts a jar produced by *another task in the same build* on
`:web:vaadinBuildFrontend`'s runtime classpath, which the Flow plugin
folds into a `dependencyJarFingerprint` scalar `@Input`. In
[vaadin/flow#25387](https://github.com/vaadin/flow/issues/25387) that
scalar comes from a standalone `project.provider { dependencyJarFiles.files … }`
that does not carry the file collection's task dependencies, so it is
computed before `lib.jar` exists on a cold build and changes on the next
one: two cache keys for one unchanged tree, `UP-TO-DATE` only on the
third build. Scenario I is the guard.

The instability **only appears under Gradle's configuration cache**.
Measured against Vaadin 25.2.6 on this fixture: with `--configuration-cache`
the second of two identical builds re-executes and Gradle re-stores the CC
entry (`cannot be reused because file 'lib/build/libs/lib.jar' has
changed`); without it, the second build is plain UP-TO-DATE and the bug is
invisible. That is why cold mode runs the whole scenario set twice, once
per configuration-cache pass — a scenario I without CC would pass on the
broken plugin.

Because everything the scenarios edit lives under `web/`, the runner
addresses scenario paths through `$MODULE_DIR` (`""` for the
single-module projects, `web/` here) and the asserted task through
`$VBF_TASK`. `BUILD_DIRS` lists every module's `build/` so
`scenario_begin` wipes `lib/build` too — that is what makes `lib.jar` as
absent at the start of each scenario as it is in a fresh checkout, which
is the state that exposes the bug.

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
- **I**: two identical consecutive builds (`scenario-i-1.log`,
  `scenario-i-2.log`); the second must be **UP-TO-DATE**. The only scenario
  asserting UP-TO-DATE. A bare SUCCESS means the cache key moved between
  two builds of an unchanged tree — vaadin/flow#25387; FROM-CACHE means
  Gradle discarded and restored outputs it should have recognised as
  current (how the bug reads once the second key is in the cache).
  - **Requires the configuration cache.** Measured against Vaadin 25.2.6:
    without `--configuration-cache` the repeat build is UP-TO-DATE even on
    the broken plugin, so the CC-off pass's copy of this scenario is only a
    cheap sanity check. The CC pass is the real guard.
  - In the CC pass the scenario also asserts Gradle **stored** an entry on
    the first build (after `cc_reset`, so it is a genuine store) and
    **reused** it on the second. A re-store is the same bug reported by
    Gradle itself, and it names the culprit: `configuration cache cannot be
    reused because file 'lib/build/libs/lib.jar' has changed`.
  - Load-bearing only for `multimodule-jar`: the single-module projects
    have no project jars in that fingerprint.
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
- **S**: CC pass only. Adds a **contentless** marker jar as a file-based
  dependency (`implementation files(...)`, injected by
  `scripts/file-dep-init.gradle` with `-PfileDepJar`) and asserts the entry
  is `STORED` with no problems. The guard for the `classFinderClasspath`
  serialization defect: a file-based dependency makes that field a *filtered*
  `FileCollection` whose filter is a Java lambda, which Gradle cannot write
  into the entry, so the build **fails** ("Configuration cache state could not
  be cached … `classFinderClasspath` of `GradlePluginAdapter`", then "entry
  discarded due to serialization error"). The same dependency as a Maven
  coordinate stores cleanly — the declaration's *shape* is the trigger. The
  jar is one text file (`build_marker_jar`, built with the JDK's `jar` into
  `fixtures/build/`): no classes, no frontend, so S varies nothing but that
  shape, and the rest of the pass — which declares no file dependencies — is
  its control. Its `run_gradle` exit code is tolerated (`|| true`) on purpose,
  so the verdict comes from `assert_cc_stored`, which prints the offending
  `classFinderClasspath` line, instead of from a bare `set -e` abort. Runs
  **first** of the two CC-only scenarios, ahead of CC-FRESH: any red scenario
  aborts the pass under `set -e`, so they are ordered by cost and severity —
  S is one build for a build-breaking defect, CC-FRESH two (one a full
  frontend regeneration) for a wasted reconfiguration.
- **H ordering**: scenario H runs in its normal position with the
  configuration cache off, but **last** in the CC pass. On a plugin carrying
  the same `classFinderClasspath` defect H fails the *build*, not just an
  assertion, and `set -e` would then abort the pass before R and CC-FRESH
  report. It is defined as `run_scenario_h()` with two call sites for that
  reason. S exists next to it because H's jar also carries a frontend module,
  so a red H has two readings; S has one.
- **R**: Relocatability. Runs by default in cold mode (A–I plus R). Its
  second build at the relocated path asserts **UP-TO-DATE** — scenario I's
  invariant from the cache consumer's side; it is the cheap guard that a
  relocated consumer settles after one build. In the CC pass both of its
  builds assert **STORED**, not reused: the copy excludes `./.gradle` so
  the tree starts with no entry, and its two builds request different task
  sets (`clean build` then `build`), which are different entries. Copy
  the project to a fresh absolute path (via `tar --dereference`, excluding
  `node_modules`/`build`/`.gradle` **and** the generated frontend surface —
  the whole `src/main/frontend` tree, `src/main/bundles`,
  `src/main/dev-bundle`) and build there against the **same** shared cache
  → FROM-CACHE. Guards against absolute paths leaking into the cache key —
  the reason a *shared* cache exists. `--dereference` resolves the platform
  mirrors' top-level symlinks so the copy is a fully independent tree. The
  generated-frontend excludes make the copy match a fresh git checkout (all
  those paths are gitignored): copying them in instead plants pre-existing
  task outputs at a checkout with no `.gradle` history, which Gradle flags
  as `OVERLAPPING_OUTPUTS` (on `src/main/frontend/index.html`) and marks
  `:vaadinBuildFrontend` non-cacheable — a *false* failure that would mask
  the real guard. Was historically opt-in while `:vaadinBuildFrontend`
  re-executed at a new path: six `@Input` **value** properties on
  `VaadinBuildFrontendTask` held absolute directory paths hashed verbatim
  into the key (`frontendDirectory`, `frontendOutputDirectory`,
  `javaSourceFolder`, `javaResourceFolder`, `npmFolder`,
  `resourcesOutputDirectory`), while the real content inputs relocated fine
  (`IGNORED_PATH`/`CLASSPATH`/`RELATIVE_PATH`). The Flow plugin now makes
  those path properties path-insensitive, so R is a standard cold-mode
  guard; if it regresses, pin the cause with `-Dorg.gradle.caching.debug`
  (`--cache-debug`) and diff the key breakdown across two checkouts.

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
2. `scenarios-cold` (matrix over all subprojects **× `cc: [off, on]`**)
   restores the artifact, runs `--cache=cold --cc=<leg>`, and saves
   `~/.gradle/caches/build-cache-1` under a key scoped to
   `(matrix.project, flow-sha, run_id, run_attempt)`. Including
   `run_attempt` matters — Actions cache writes are write-once, so
   without it a "Re-run all jobs" would no-op against the prior
   attempt's cache. For that same write-once reason **only the `cc: off`
   leg saves**: the key is deliberately not scoped by `matrix.cc`,
   because the warm job restores one key and must not have to pick a
   leg, so two writers would be a race. A side benefit is that a
   configuration-cache regression cannot starve the warm job.
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
   `BUILD_TASK`, `ARCHIVE_GLOB`, and `BUNDLE_PREFIX`. A multi-module
   project also overrides `MODULE_DIR` (path prefix of the Vaadin
   module, trailing slash), `VBF_TASK` (the asserted task path),
   `BUILD_DIRS` (every module's build dir) and `AUX_TASKS` (qualified
   sources/javadoc task paths); the defaults above the `case` cover the
   single-module shape. `CC_COMPATIBLE` defaults to `1`; set it to `0` only
   if the project's plugin stack cannot build under `--configuration-cache`,
   with a comment naming the offending plugin (probe first — see README's
   "Configuration cache" section; all seven current projects are
   compatible). `BUNDLE_PREFIX`
   is the prefix inside the archive where the Flow plugin stages the
   bundle (`""` for jars, `WEB-INF/classes/` for wars). Spring Boot
   `bootJar` also uses `""`: since Flow PR #25001 (25.3.0-alpha4) the
   bundle is staged at the archive **root** (`META-INF/VAADIN/...`), not
   under `BOOT-INF/classes/` — see vaadin/flow#25021.
3. Add `new-project` to both matrix lists in
   `.github/workflows/build-cache.yml` (cold and warm), and to the
   `ALL_PROJECTS` array in `scripts/run-suite.sh`.
4. Add the published-mode mirror `platform/new-project/`: a real
   `build.gradle` (same non-Vaadin config, but `id 'com.vaadin'` in
   place of `com.vaadin.flow`, no `mavenLocal()`, and
   `com.vaadin:flow:${flowVersion}` resolved from Central/prereleases)
   and `settings.gradle`, plus **symlinks** `src -> ../../new-project/src`,
   `gradle -> ../../new-project/gradle`, `gradlew`, `gradlew.bat`. A
   multi-module mirror keeps the wrapper symlinks at the top level but
   needs one `src` symlink **per module** (see `platform/multimodule-jar`,
   which has `lib/src` and `web/src`). Then
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
