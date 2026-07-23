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
| `custom-frontend-output` | `java`, `application`, `com.vaadin.flow` + custom `vaadin.frontendOutputDirectory` | `build`      | `*.jar` (bundle at root)                 | Bundle **in** main archive; sources/javadoc jars **clean** |

All six projects exercise the same cache scenarios and the same
archive-content expectation: a Flow application archive must contain
the production frontend bundle under `META-INF/VAADIN/webapp/`.
`shaded-jar` and `custom-jar-task` cover archive-task shapes that the
Flow Gradle plugin must recognise (Shadow's `shadowJar` and any
user-defined `Jar` subtype). `custom-frontend-output` mirrors
`plain-jar` but overrides the plugin's `frontendOutputDirectory` —
declared `@Input` on both `vaadinPrepareFrontend` and
`vaadinBuildFrontend`, so a regression in its cache wiring or
jar-packaging path resolution would surface here. A failure on these
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

For each project, in **cold** cache mode the suite runs these scenarios
in order. Every scenario also asserts the **produced bundle content**,
not just the task outcome: cache hits must keep the scenario-A baseline
`stats.json` signature, and frontend-changing misses must change it (and
stage the expected module). That catches a false cache hit that serves a
*stale* bundle — something an outcome-only check is blind to.

Cache-**hit** guards (must come `FROM-CACHE`, bundle unchanged):

| # | Scenario              | Why it must still hit |
|---|-----------------------|-----------------------|
| A | Cold-cache restore: build → `rm -rf build/` → build | `SUCCESS` then `FROM-CACHE` — populates the baseline |
| B | Add a test class (not a `vaadinBuildFrontend` input) | test sources don't affect the bundle |
| C | Edit `src/main/resources/messages.properties`       | not a declared input |
| E | Append a comment after the final `}` of the view    | byte-identical bytecode → normalized key still hits |
| R | Build a copy of the project at a **different absolute path** against the same shared cache | proves the cache key is relocatable, not path-bound |

Cache-**miss** guards (must **not** come `FROM-CACHE`):

| # | Scenario              | Why it must miss |
|---|-----------------------|------------------|
| D | Modify the `@Route` view's Java code                | main-classpath bytecode is an input (bundle itself unchanged — heading is server-side) |
| F | Add a `@JsModule` referencing a project frontend file | new frontend module changes the bundle |
| G | Edit `src/main/frontend/index.html`                 | the app-shell template is a frontend input |
| H | Add a dependency jar carrying a `@Route` view with a `@JsModule` (a frontend add-on) | a dependency's frontend is a cache input, staged without any app source change |

Scenarios D–H are the negative/positive-invalidation guards; E, B, C and
R guard against an over-eager key that rebuilds (or fails to relocate)
when nothing bundle-relevant changed. The add-on jar for H is the
buildable fixture in `fixtures/demo-addon/`, injected via
`scripts/addon-init.gradle` (no project `build.gradle` edit).

Scenario **R runs in cold mode by default**, alongside A–H. It builds a
copy of the project at a fresh absolute path against the *same* shared
cache and requires `:vaadinBuildFrontend` to come `FROM-CACHE` — the whole
point of a shared cache being reuse across checkouts at different paths.
This guards against absolute paths leaking back into the cache key. (It
was historically opt-in while `:vaadinBuildFrontend` had a path-dependent
key; the Flow plugin now makes that key path-insensitive, so R is a
standard guard.) If R ever regresses, re-run with `--cache-debug` and diff
the key breakdown to see *which* inputs turned path-dependent (see
[Debugging the cache key](#debugging-the-cache-key)).

In **warm** cache mode (the default) the suite skips the cold scenarios
and instead
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
# Cold mode: wipe ~/.gradle/caches/build-cache-1 and run scenarios A–H + R.
bash scripts/run-project.sh --cache=cold plain-jar "$FLOW_VERSION"

# Warm mode (default): leave the cache alone and assert that a
# clean build hits it. Requires the cache to be populated already.
bash scripts/run-project.sh plain-jar "$FLOW_VERSION"
```

### Run the whole suite

`scripts/run-suite.sh` drives `run-project.sh` over every project and
prints a per-project PASS/FAIL summary (exit non-zero if any failed):

```bash
# Run the full cold scenario set (A–H + R) for every project. This is the complete
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
for p in plain-jar war spring-boot-jar shaded-jar custom-jar-task custom-frontend-output; do
  bash scripts/run-project.sh --cache=cold "$p" "$FLOW_VERSION"
done
```

### Testing against published Vaadin artifacts

The projects above build against a locally-installed Flow snapshot. To
instead validate a **published** Vaadin release (from Maven Central or
the Vaadin pre-releases repo), each project has a mirror under
`platform/` that applies the Vaadin *platform* plugin (`id 'com.vaadin'`,
versioned by the Vaadin platform version) and resolves `com.vaadin:flow`
from the published repositories. The `platform/<project>` mirrors share
the same fixture sources as their root counterparts via a symlinked
`src/`, so the scenarios are identical — only the plugin and where
artifacts come from differ. This path requires **Vaadin 25+**.

The Vaadin platform version and the Flow version are **not** aligned at
the patch level (e.g. Vaadin `25.2.3` ships Flow `25.2.4`), so pass the
**Vaadin** version and let the Flow version be derived from it (via
`scripts/resolve-flow-version.sh`, which reads `<flow.version>` from the
`com.vaadin:vaadin-gradle-plugin` POM):

```bash
# One project, published mode. The trailing version is a Vaadin platform
# version; the Flow version is derived from it. Final/beta/rc resolve from
# Maven Central, alpha/SNAPSHOT from vaadin-prereleases.
bash scripts/run-project.sh --cache=cold --vaadin-platform plain-jar 25.2.3

# Override the derived Flow version.
bash scripts/run-project.sh --cache=cold --vaadin-platform --flow-version=25.2.4 plain-jar 25.2.3

# The whole suite against a published version.
bash scripts/run-suite.sh --vaadin-platform 25.2.3
```

Because the `platform/<project>/src` symlink is shared with the
corresponding root project, don't run a project's source-mode and
published-mode suites **concurrently** on the same machine — the
frontend build writes into the shared source tree. Sequential runs and
CI (isolated runners) are unaffected.

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

### Debugging the cache key

When a scenario misses the cache and you need to know *why*, pass
`--cache-debug` (or set `CACHE_DEBUG=1`). It adds
`-Dorg.gradle.caching.debug=true` to every Gradle invocation, so each
cacheable task logs the individual inputs hashed into its build-cache
key (`Appending … to build cache key` lines) followed by the final key.
Diffing those lines between two builds pinpoints which input changed.

```bash
# Cold suite (A–H plus R) with the key breakdown logged.
bash scripts/run-project.sh --cache=cold --cache-debug plain-jar "$FLOW_VERSION"

# Extract the :vaadinBuildFrontend block from the original build and the
# relocated build, then diff (each log lives in the project dir):
cd plain-jar
extract() {
  awk '/^Appending /{b[n++]=$0;next}
       /^Build cache key for task/{if($0~/:vaadinBuildFrontend'\''/){for(i=0;i<n;i++)print b[i];print}n=0;delete b;next}
       {n=0;delete b}' "$1"
}
diff <(extract scenario-a-1.log) <(extract scenario-r.log)
```

With a relocatable plugin the two blocks are identical (empty diff) —
that is scenario R passing. This is also how the original
path-dependence was pinned down: the diff used to surface six `@Input`
**value** properties on `VaadinBuildFrontendTask` that held absolute
directory paths hashed verbatim (`frontendDirectory`,
`frontendOutputDirectory`, `javaSourceFolder`, `javaResourceFolder`,
`npmFolder`, `resourcesOutputDirectory`), while the genuine content
inputs (`applicationProperties` as `IGNORED_PATH`, `projectClassesDirs`
as `CLASSPATH`) already kept an identical fingerprint across paths. The
plugin now makes those path properties path-insensitive, so if the diff
is ever non-empty again it points straight at the regression.

## CI workflow

`.github/workflows/build-cache.yml` runs the same scenarios in CI. It
is triggered manually via `workflow_dispatch`, with inputs:

- `flow_repo` (default `vaadin/flow`) — Flow repo (supports forks).
- `flow_ref` (default `main`) — branch, tag, or SHA.
- `flow_version` (optional) — a **published** Flow version. When set,
  `build-flow` is skipped entirely and the scenario jobs resolve Flow
  directly from Maven Central / vaadin-prereleases (no local build,
  no `flow-m2` artifact). `flow_repo`/`flow_ref` are then ignored. This
  is the source-mode (`com.vaadin.flow` plugin) counterpart to the
  platform-mode published workflow below.

The workflow has three job groups:

1. **`build-flow`** — checks out the requested Flow ref and installs
   the Gradle plugin to `~/.m2/repository`, then uploads those
   artifacts. Skipped when `flow_version` is set.
2. **`scenarios-cold`** — matrix over all 6 projects. When building
   from source, each job downloads the Flow artifacts into mavenLocal;
   with `flow_version` set it skips that and lets Gradle resolve the
   published Flow. Each job runs
   `scripts/run-project.sh --cache=cold` (scenarios A–H plus the
   relocatability guard R) and persists the resulting
   `~/.gradle/caches/build-cache-1` under a run-scoped Actions cache
   key (discriminated by the built Flow SHA, or the published version).
3. **`scenarios-warm`** — `needs: scenarios-cold`, matrix over all 6
   projects. Each job restores the matching cold job's cache on a
   fresh runner and runs `scripts/run-project.sh --cache=warm`. A
   cache miss is a hard failure (`fail-on-cache-miss: true`) because
   the assertion is meaningless without a real restoration.

Failed runs upload `cold-<project>-logs` / `warm-<project>-logs`
artifacts containing the Gradle logs.

### Published-artifact workflow

`.github/workflows/build-cache-published.yml` runs the same cold/warm
matrix against a **published** Vaadin release instead of a locally-built
Flow. It is `workflow_dispatch` only, with inputs:

- `vaadin_version` (required) — the Vaadin platform version (25+).
- `flow_version` (optional) — override the derived Flow version.

It has no `build-flow` job. Instead a **`resolve-version`** job derives
the Flow version from the Vaadin version (unless overridden), then the
`scenarios-cold` and `scenarios-warm` matrices build the `platform/`
projects, keying the persisted build-cache on the Vaadin and Flow
versions. Final/beta/rc versions resolve from Maven Central; alpha and
SNAPSHOT versions from the Vaadin pre-releases repo.

### Validating a Flow PR

Dispatch the workflow with `flow_ref=<pr-branch-name>` (or the PR's
head SHA). Re-run with `flow_ref=<pre-fix-SHA>` to confirm the test
suite actually catches the regression the PR fixes — if both runs pass,
the workflow is not exercising what we think it is.

## Layout

```
.
├── README.md                          # this file
├── .github/workflows/
│   ├── build-cache.yml                # source mode (builds Flow from a ref)
│   └── build-cache-published.yml      # published mode (Central / pre-releases)
├── scripts/
│   ├── run-suite.sh
│   ├── run-project.sh
│   ├── resolve-flow-version.sh        # Vaadin version -> Flow version
│   └── assert-task-outcome.sh
├── plain-jar/                         # source-mode projects (com.vaadin.flow)
├── war/
├── spring-boot-jar/
├── shaded-jar/
├── custom-jar-task/
├── custom-frontend-output/
└── platform/                          # published-mode mirrors (com.vaadin)
    ├── plain-jar/                     #   build.gradle + settings.gradle,
    ├── war/                           #   with src/ and the wrapper symlinked
    ├── spring-boot-jar/               #   back to the root project
    ├── shaded-jar/
    ├── custom-jar-task/
    └── custom-frontend-output/
```
