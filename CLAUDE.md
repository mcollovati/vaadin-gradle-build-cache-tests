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

`scripts/run-project.sh` drives every subproject through the same
fixed scenario set (A/B/C/D in cold mode, single FROM-CACHE assertion
in warm mode). It looks up project-specific values (build task,
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
# Cold: wipes ~/.gradle/caches/build-cache-1, runs scenarios A/B/C/D.
bash scripts/run-project.sh --cache=cold plain-jar "$FLOW_VERSION"

# Warm (default): leaves cache alone, asserts clean build → FROM-CACHE.
bash scripts/run-project.sh plain-jar "$FLOW_VERSION"
```

Warm mode requires the cache to already be populated (cold run first,
or restored Actions cache in CI). The runner's per-project parameters
(build task, archive path, in-archive prefix) live in the `case`
statement at `scripts/run-project.sh:170`.

## Scenarios (cold mode)

Each scenario is destructive but registers an undo via
`register_cleanup` **before** the destructive step, so an aborted run
still leaves a clean working tree (EXIT trap → `flush_cleanups`).

- **A**: build → `rm -rf build/` → build. Expect SUCCESS then FROM-CACHE.
- **B**: Add `src/test/java/com/example/AddedTest.java` → build. FROM-CACHE.
- **C**: Append to `src/main/resources/messages.properties` → build. FROM-CACHE.
  - Uses `messages.properties` specifically because it is **not**
    declared as an input of `vaadinBuildFrontend`.
    `application.properties` is declared as `@InputFile` with content
    sensitivity, so editing it correctly invalidates the cache and is
    not a useful negative case.
- **D**: Edit `HelloView.java` heading literal → build. NOT_FROM_CACHE
  (negative assertion — guards against an over-eager cache key that
  ignores main-classpath bytecode).

## CI workflow

`.github/workflows/build-cache.yml` is `workflow_dispatch` only.
Inputs `flow_repo` (default `vaadin/flow`) and `flow_ref` (default
`main`) let it run against any branch/tag/SHA, including PR branches
on forks. Three jobs:

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
   existing subprojects — scenarios B/C/D edit those exact paths.
2. Add a `case` branch in `scripts/run-project.sh` setting
   `BUILD_TASK`, `ARCHIVE_GLOB`, and `BUNDLE_PREFIX`. `BUNDLE_PREFIX`
   is the prefix inside the archive where the Flow plugin stages the
   bundle (`""` for jars, `WEB-INF/classes/` for wars,
   `BOOT-INF/classes/` for Spring Boot).
3. Add `new-project` to both matrix lists in
   `.github/workflows/build-cache.yml` (cold and warm).
4. Update the project table in `README.md`.

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
