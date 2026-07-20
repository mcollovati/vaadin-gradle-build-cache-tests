# Vaadin Flow Gradle build-cache validation projects

A small suite of standalone Gradle projects that exercise the Flow Gradle
plugin's `vaadinBuildFrontend` task across realistic developer edits, with
a GitHub Actions workflow that runs them on demand against any Flow ref
(branch, tag, or SHA).

The suite is designed to validate
[PR `fix-gradle-buildfrontend-cache-outputs`](https://github.com/vaadin/flow)
and to act as a regression guard for the Gradle plugin's build-cache
behaviour going forward.

## What's in here

| Project                  | Plugins                                                    | Task         | Archive layout                          | Archive expectation           |
|--------------------------|------------------------------------------------------------|--------------|------------------------------------------|-------------------------------|
| `plain-jar`              | `java`, `application`, `com.vaadin.flow`                   | `build`      | `*.jar` (bundle at root)                 | Bundle **in** main archive; sources/javadoc jars **clean** |
| `war`                    | `war`, `com.vaadin.flow`                                   | `build`      | `*.war` (bundle at `WEB-INF/classes/`)   | Bundle **in** main archive; sources/javadoc jars **clean** |
| `spring-boot-jar`        | `org.springframework.boot`, `com.vaadin.flow`              | `bootJar`    | `*.jar` (bundle at `BOOT-INF/classes/`)  | Bundle **in** main archive; sources/javadoc jars **clean** |
| `shaded-jar`             | `java`, `com.vaadin.flow`, `com.gradleup.shadow`           | `shadowJar`  | `*-all.jar` (bundle at root)             | Bundle **in** main archive; sources/javadoc jars **clean** |
| `custom-jar-task`        | `java`, `com.vaadin.flow` + a user-defined `Jar` task      | `customJar`  | `custom-jar.jar` (bundle at root)        | Bundle **in** main archive; sources/javadoc jars **clean** |
| `custom-frontend-output` | `java`, `application`, `com.vaadin.flow` + custom `vaadin.frontendOutputDirectory` (ends in `META-INF/VAADIN/webapp`) | `build`      | `*.jar` (bundle at root)                 | Bundle **in** main archive; sources/javadoc jars **clean** |
| `custom-frontend-output-flat` | reuses the `custom-frontend-output` module; overrides `vaadin.frontendOutputDirectory` to a path that does **not** end in `META-INF/VAADIN/webapp` | `build`      | `*.jar` (bundle at root)                 | Bundle **in** main archive; sources/javadoc jars **clean** |

All seven projects exercise the same cache scenarios and the same
archive-content expectation: a Flow application archive must contain
the production frontend bundle under `META-INF/VAADIN/webapp/`.
`shaded-jar` and `custom-jar-task` cover archive-task shapes that the
Flow Gradle plugin must recognise (Shadow's `shadowJar` and any
user-defined `Jar` subtype). `custom-frontend-output` mirrors
`plain-jar` but overrides the plugin's `frontendOutputDirectory` —
declared `@Input` on both `vaadinPrepareFrontend` and
`vaadinBuildFrontend`, so a regression in its cache wiring or
jar-packaging path resolution would surface here.
`custom-frontend-output-flat` reuses that same module but overrides
`frontendOutputDirectory` (via `-PcustomFrontendOutputDirectory`) to a
path that does **not** end in `META-INF/VAADIN/webapp`: the plugin must
still stage the production bundle at `META-INF/VAADIN/webapp/` inside
the archive regardless of where the frontend build writes on disk. A
regression that keys the in-archive location off the literal
`frontendOutputDirectory` segments — or that silently drops the bundle
when those segments are absent — surfaces here. A failure on these
projects is a plugin regression, not an expected outcome.

Every project also publishes a `-sources.jar` and a `-javadoc.jar` via
`java { withSourcesJar(); withJavadocJar() }`. The runner asserts those
auxiliary archives contain **no** `META-INF/VAADIN/` entries — a
symmetric negative guard against the Flow Gradle plugin wiring its
bundle-staging into non-application `Jar` tasks. A failure here means
the plugin is leaking the production frontend bundle (or `flow-build-info.json`,
`stats.json`, etc.) into archives that should ship only `.java` sources
or javadoc HTML.

## Scenarios

For each project, in **cold** cache mode the suite runs four scenarios
in order:

| # | Scenario              | Expected `vaadinBuildFrontend` outcome |
|---|-----------------------|----------------------------------------|
| A | Cold-cache restore: build → `rm -rf build/` → build | `SUCCESS` then `FROM-CACHE` |
| B | Add a test class then build with a clean output tree | `FROM-CACHE` |
| C | Edit `src/main/resources/messages.properties` then build | `FROM-CACHE` |
| D | Modify the `@Route` view's Java code then build      | not from cache (re-executes) |

Scenario D is the negative assertion that proves the cache key is
sensitive to main-classpath bytecode changes — useful as a guard
against an over-eager future change that would weaken the cache key.

In **warm** cache mode (the default) the suite skips A–D and instead
runs one `clean <build-task>` asserting `:vaadinBuildFrontend ==
FROM-CACHE`. The warm path is what CI uses to validate that a cache
written by a previous job (then persisted to and re-fetched from
Actions cache storage) is usable on a fresh runner.

## Running locally

### Prerequisites

- Java 21+ (Temurin recommended)
- Gradle: not needed on `PATH` — each project ships a wrapper
  (`./gradlew`). `scripts/run-project.sh` auto-detects the wrapper;
  export `GRADLE_BIN=/path/to/gradle` to override.
- Node.js 22+
- A Flow checkout you want to test, with the plugin installed locally
  to `~/.m2/repository`. From your Flow checkout:

  ```bash
  ./mvnw -B -DskipTests -am -pl flow-plugins/flow-gradle-plugin install
  ```

  Capture the version it published:

  ```bash
  FLOW_VERSION=$(cd /path/to/flow && ./mvnw -q help:evaluate -Dexpression=project.version -DforceStdout)
  echo "$FLOW_VERSION"   # e.g. 25.2-SNAPSHOT
  ```

### Run one project

```bash
cd plain-jar
./gradlew clean build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
unzip -l build/libs/plain-jar.jar | grep META-INF/VAADIN/webapp/
```

Or run the scripted scenarios. The runner has two cache modes:

```bash
# Cold mode: wipe ~/.gradle/caches/build-cache-1 and run scenarios A/B/C/D.
bash scripts/run-project.sh --cache=cold plain-jar "$FLOW_VERSION"

# Warm mode (default): leave the cache alone and assert that a
# clean build hits it. Requires the cache to be populated already.
bash scripts/run-project.sh plain-jar "$FLOW_VERSION"
```

### Run the whole suite

`scripts/run-suite.sh` drives `run-project.sh` over every project and
prints a per-project PASS/FAIL summary (exit non-zero if any failed):

```bash
# Run cold scenarios (A/B/C/D) for every project. This is the complete
# local validation — each project's cold run primes and hits its own
# cache within scenario A, so no separate warm phase is needed locally.
bash scripts/run-suite.sh "$FLOW_VERSION"

# Options:
bash scripts/run-suite.sh --fail-fast "$FLOW_VERSION"              # stop at first failure
bash scripts/run-suite.sh --projects="plain-jar war" "$FLOW_VERSION"  # subset
```

`--cache=warm` runs the warm assertion for every project, but note that
cold mode wipes the *shared* `build-cache-1` on each invocation, so a
local cold-all run does not leave every project's cache in place — the
last cold project wins. Warm-all is a CI concern, where each project's
cache is persisted and restored in isolation (see the workflow below).
To reproduce the old two-loop behaviour by hand:

```bash
for p in plain-jar war spring-boot-jar shaded-jar custom-jar-task custom-frontend-output custom-frontend-output-flat; do
  bash scripts/run-project.sh --cache=cold "$p" "$FLOW_VERSION"
done
```

### Wiping the build cache

The local Gradle build cache lives at
`$GRADLE_USER_HOME/caches/build-cache-1/` — default
`~/.gradle/caches/build-cache-1/`. `--cache=cold` wipes it before
running; otherwise the script never touches it.

To wipe by hand:

```bash
rm -rf "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/build-cache-1"
```

To bypass the cache for a single Gradle invocation without deleting it,
add `--no-build-cache` to the command line. Note that the rm form
affects every Gradle project on the machine sharing the same
`GRADLE_USER_HOME`, so be deliberate.

## CI workflow

`.github/workflows/build-cache.yml` runs the same scenarios in CI. It
is triggered manually via `workflow_dispatch`, with inputs:

- `flow_repo` (default `vaadin/flow`) — Flow repo (supports forks).
- `flow_ref` (default `main`) — branch, tag, or SHA.

The workflow has three job groups:

1. **`build-flow`** — checks out the requested Flow ref and installs
   the Gradle plugin to `~/.m2/repository`, then uploads those
   artifacts.
2. **`scenarios-cold`** — matrix over all projects. Each job
   downloads the Flow artifacts, runs
   `scripts/run-project.sh --cache=cold`, and persists the resulting
   `~/.gradle/caches/build-cache-1` under a run-scoped Actions cache
   key.
3. **`scenarios-warm`** — `needs: scenarios-cold`, matrix over all
   projects. Each job restores the matching cold job's cache on a
   fresh runner and runs `scripts/run-project.sh --cache=warm`. A
   cache miss is a hard failure (`fail-on-cache-miss: true`) because
   the assertion is meaningless without a real restoration.

Failed runs upload `cold-<project>-logs` / `warm-<project>-logs`
artifacts containing the Gradle logs.

### Validating a Flow PR

Dispatch the workflow with `flow_ref=<pr-branch-name>` (or the PR's
head SHA). Re-run with `flow_ref=<pre-fix-SHA>` to confirm the test
suite actually catches the regression the PR fixes — if both runs pass,
the workflow is not exercising what we think it is.

## Layout

```
.
├── README.md                          # this file
├── .github/workflows/build-cache.yml
├── scripts/
│   ├── run-suite.sh
│   ├── run-project.sh
│   └── assert-task-outcome.sh
├── plain-jar/
├── war/
├── spring-boot-jar/
├── shaded-jar/
├── custom-jar-task/
└── custom-frontend-output/         # also drives custom-frontend-output-flat
```
