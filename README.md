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
| `multimodule-jar`        | two modules: `:lib` (`java`) and `:web` (`java`, `application`, `com.vaadin.flow`, `implementation project(':lib')`) | `:web:build` | `web/*.jar` (bundle at root)             | Bundle **in** main archive; sources/javadoc jars **clean** |

All seven projects exercise the same cache scenarios and the same
archive-content expectation: a Flow application archive must contain
the production frontend bundle under `META-INF/VAADIN/webapp/`.
`shaded-jar` and `custom-jar-task` cover archive-task shapes that the
Flow Gradle plugin must recognise (Shadow's `shadowJar` and any
user-defined `Jar` subtype). `custom-frontend-output` mirrors
`plain-jar` but overrides the plugin's `frontendOutputDirectory` —
declared `@Input` on both `vaadinPrepareFrontend` and
`vaadinBuildFrontend`, so a regression in its cache wiring or
jar-packaging path resolution would surface here. `multimodule-jar` is
the only multi-module project: its Vaadin module depends on a sibling
module, so `:web:vaadinBuildFrontend` has a jar built by *another task in
the same build* on its runtime classpath. That is the shape behind
[vaadin/flow#25387](https://github.com/vaadin/flow/issues/25387) — on the
cold build that jar does not exist yet when the task's inputs are
snapshotted, so a dependency-jar fingerprint computed without the file
collection's task dependencies changes between two identical builds.
Scenario I is the guard. A failure on these projects is a plugin
regression, not an expected outcome.

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

Cache-**hit** guards (the task must not re-execute; bundle unchanged):

| # | Scenario              | Why it must still hit |
|---|-----------------------|-----------------------|
| A | Cold-cache restore: build → `rm -rf build/` → build | `SUCCESS` then `FROM-CACHE` — populates the baseline |
| I | Two identical consecutive builds                     | `UP-TO-DATE` on the second — identical inputs must produce an identical key twice |
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

Scenarios D–H are the negative/positive-invalidation guards; E, B, C, I
and R guard against an over-eager key that rebuilds (or fails to
relocate) when nothing bundle-relevant changed. The add-on jar for H is the
buildable fixture in `fixtures/demo-addon/`, injected via
`scripts/addon-init.gradle` (no project `build.gradle` edit).

Two further scenarios, **S** and **CC-FRESH**, run only under the
configuration cache, where what they guard is visible at all — see
[Configuration cache](#configuration-cache).

Scenario **I** is the only one that asserts `UP-TO-DATE` rather than
`FROM-CACHE`. It runs two identical builds back to back: after the first,
nothing changes, so the second must be `UP-TO-DATE`. A bare `SUCCESS`
means the cache key moved between two builds of an unchanged tree;
`FROM-CACHE` means Gradle discarded and restored outputs it should have
recognised as current (how the bug reads once that second key is in the
cache). It is load-bearing only for `multimodule-jar`, whose
dependency-jar fingerprint contains a jar that does not exist yet when the
task's inputs are first snapshotted
([vaadin/flow#25387](https://github.com/vaadin/flow/issues/25387)).

**Scenario I needs the configuration cache to catch that bug.** Measured
against Vaadin 25.2.6 on this fixture: with `--configuration-cache` the
second build re-executes and Gradle re-stores its entry, reporting
`configuration cache cannot be reused because file 'lib/build/libs/lib.jar'
has changed`; *without* it, the second build is plain `UP-TO-DATE` and the
regression is invisible. That is why the whole scenario set is run twice —
see [Configuration cache](#configuration-cache) below.

Scenario R's second build asserts the same UP-TO-DATE invariant at the
relocated path, a general guard that a relocated consumer settles after
one build.

Scenario **R runs in cold mode by default**, alongside A–I. It builds a
copy of the project at a fresh absolute path against the *same* shared
cache and requires `:vaadinBuildFrontend` to come `FROM-CACHE` — the whole
point of a shared cache being reuse across checkouts at different paths.
This guards against absolute paths leaking back into the cache key. (It
was historically opt-in while `:vaadinBuildFrontend` had a path-dependent
key; the Flow plugin now makes that key path-insensitive, so R is a
standard guard.) If R ever regresses, re-run with `--cache-debug` and diff
the key breakdown to see *which* inputs turned path-dependent (see
[Debugging the cache key](#debugging-the-cache-key)).

## Configuration cache

Gradle's configuration cache is not a second feature tested alongside the
build cache — it is an **execution mode** that changes *when* a task's
inputs are computed, and therefore what ends up in its build-cache key.
vaadin/flow#25387 is exactly that: a build-cache key bug that is invisible
with the configuration cache off.

So cold mode runs the **same scenario set twice** — `--cc=off`, then
`--cc=on` — and each pass re-wipes the shared build cache so both start
cold. The CC pass adds one assertion per scenario about the fate of
Gradle's *entry*, plus two CC-only scenarios:

| Scenario | Entry must be | Why |
|---|---|---|
| A (both builds) | `STORED` | `clean build …` and `build …` request different task sets, and the requested task set is part of an entry's identity |
| I | `REUSED` | the #25387 guard: nothing changed, so nothing may invalidate |
| B, C, D, E, F, G | `REUSED` | the uniform invariant — no ordinary source, resource or frontend edit may invalidate the entry. Each also wipes `build/` first, so this doubles as "deleting outputs must not invalidate it either" |
| R (both builds) | `STORED` | the relocated copy excludes `./.gradle`, so it starts with no entry |
| **S** | `STORED` | CC pass only: a **file-based** `files(…)` dependency must not make `:vaadinBuildFrontend` unserializable |
| **CC-FRESH** | `STORED` then `REUSED` | CC pass only: no `src/main/frontend` (as on a real checkout), build, build again |
| H | `STORED` | `--init-script` plus a new `-P` property change the build logic, so a fresh entry is correct |

**Scenario S** is the file-dependency guard. A project that declares
`implementation files('libs/some-local.jar')` cannot be built with the
configuration cache at all on a plugin carrying the `classFinderClasspath`
defect: the field is a *filtered* `FileCollection` whose filter is a Java
lambda, the JDK refuses reflective access to the lambda's captured
arguments, and the store aborts —

```
Configuration cache state could not be cached: … field `classFinderClasspath`
of `com.vaadin.flow.gradle.GradlePluginAdapter` … error writing value
> Unable to make field … accessible: module java.base does not "opens
  java.util.function" to unnamed module
Configuration cache entry discarded due to serialization error.
```

The build **fails**; it does not degrade. The same dependency added as a
Maven coordinate stores cleanly, so the shape of the declaration is the
trigger, not the act of adding a dependency. There is a build-cache
consequence too: a build that dies during the store can leave
`src/main/frontend/index.html` on disk with no matching task history, which
makes the next build report `[OVERLAPPING_OUTPUTS]` and mark
`:vaadinBuildFrontend` **non-cacheable**.

S's jar is a **contentless marker** — one text file, no classes, no
frontend resources — built by `build_marker_jar` into `fixtures/build/` and
injected via `scripts/file-dep-init.gradle`. That is what separates it from
H, whose jar exists precisely to carry a frontend module: H trips the same
defect, but only as a side effect, so a red H has two possible readings.
S varies nothing but the dependency's shape, and the rest of the pass —
which declares no file dependencies — is its control. Its build's exit code
is tolerated on purpose, so the verdict comes from `assert_cc_stored` (which
prints the offending `classFinderClasspath` line) rather than from a bare
`set -e` abort.

S is the **first** of the two CC-only scenarios, ahead of CC-FRESH. Under
`set -e` any red scenario aborts the pass and hides the ones behind it, so
they are ordered by cost and severity: S is a single build guarding a defect
that breaks the build outright, where CC-FRESH spends two builds (one a full
frontend regeneration) on a wasted reconfiguration.

Scenario **H runs last in the CC pass** (in its normal position when the
configuration cache is off). On a plugin carrying that same serialization
defect it fails the *build*, not just an assertion, and under `set -e` that
would abort the pass before R and CC-FRESH ever report — a known-red
scenario must not mask the ones behind it.

A configuration-time input therefore reads as a **red CC pass against a
green CC-off pass**, and Gradle names the offending path itself. That
contrast is the diagnosis.

**CC-FRESH** is the fresh-checkout guard. `.gitignore` ignores
`**/src/main/frontend/` entirely, so on a real checkout that directory does
not exist and the first build creates it. A plugin that probes it while
configuring the task graph makes the *next* build invalidate with
`the file system entry '…/src/main/frontend' has been created`, throwing
away a configuration-cache entry over a directory the build itself
produced.

It is **currently red** on Flow `25.3-SNAPSHOT` (and reproduces in two
builds of `plain-jar` alone). Measured cost: one extra configuration on
the first rebuild after a fresh checkout — builds 3 and 4 reuse normally,
so it is not a recurring tax. The mechanism, read off the run's own
configuration-cache report, is three file-system-entry inputs attributed
to `com.vaadin.flow.internal.FrontendUtils` — `./src/main/frontend`,
`./frontend` and `./src/main/frontend/index.ts`:

- `PluginEffectiveConfiguration.effectiveFrontendDirectory` calls
  `FrontendUtils.getFrontendFolder(npmFolder, frontendDirectory)`, which
  tests `src/main/frontend` for existence and falls back to the legacy
  `frontend/` folder;
- `reactEnable` maps over it into `FrontendUtils.isReactRouterRequired`,
  which tests `src/main/frontend/index.ts`.

Both feed task `@Input`s, so storing an entry forces them to be evaluated
and their probes become build-logic inputs. Meanwhile
`BuildFrontendOutputProperties.getFrontendIndexHtml()` declares
`src/main/frontend/index.html` as an `@OutputFile`, so Gradle materialises
that parent directory even for a `FROM-CACHE` restore — it is left empty
here — and the recorded check flips. Note the *value* never changes:
`getFrontendFolder` returns `src/main/frontend` either way, since the
legacy folder does not exist. The reconfiguration buys nothing.

Entries live in the **build root's** `.gradle/configuration-cache` (for
`multimodule-jar` that is `multimodule-jar/.gradle/`, not `web/.gradle/`),
survive `build/` being wiped, and coexist per requested task set. The
runner's `cc_reset` removes them where a scenario's premise is a freshly
stored entry (A, I and CC-FRESH); every other scenario deliberately
inherits the previous one's entry, because inheriting is what makes "an
ordinary edit must not invalidate it" testable.

A project whose plugin stack cannot build under the configuration cache
sets `CC_COMPATIBLE=0` in its `case` branch, which skips the CC pass for it
— a CC-hostile plugin produces failures about *itself*, and Gradle's
graceful degradation (`Configuration cache disabled …`, build succeeds with
no entry) would otherwise leave the assertions measuring nothing. All seven
projects are currently compatible, including `shaded-jar` (Shadow 8.3.5)
and `spring-boot-jar` (`io.spring.dependency-management`). To re-probe after
a plugin bump, run any project's build twice and read the last two lines:

```bash
cd plain-jar
for i in 1 2; do
  ./gradlew build sourcesJar javadocJar --build-cache --console=plain --no-daemon \
    --configuration-cache --configuration-cache-problems=fail \
    -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
done
```

`stored.` then `reused.` means compatible. `Configuration cache disabled …`
means it is not. Problems attributed to Shadow or dependency-management
mean `CC_COMPATIBLE=0`; problems attributed to `com.vaadin.flow` are a
**finding**, not a reason to disable the project.

The same distinction has a narrower knob. `CC_REUSE_EXEMPT` names one
invalidation reason a project is allowed to hit without failing
`assert_cc_reused`: the assertion accepts a not-reused entry whose reason
contains that substring, prints `WARN … (not the Flow plugin)`, and fails
on every other reason exactly as before. Only `spring-boot-jar` sets it, to
`build/classes/java/main`. The Spring Boot plugin probes that directory
while *configuring* `bootJar`, so the entry is invalidated by the build's
own side effect — `has been created` on the build after a wiped `build/`,
`has been removed` after `scenario_begin` wipes it again. Since every
cold-mode scenario begins by wiping `build/`, that flip repeats for the
whole pass and no scenario would ever see a reused entry. It is the same
shape as the `src/main/frontend` probe above with a different owner:
deleting `id 'com.vaadin.flow'` from the project reproduces it (Spring Boot
4.0.5, measured 2026-08-29), and only when `bootJar` is in the requested
task set — `classes`, `jar` and `sourcesJar javadocJar` all reuse the entry
although `compileJava` creates the very same directory. Upstream the cost is
bounded: the third identical build reuses.

One scenario deliberately refuses the exemption: **CC-FRESH**. Gradle prints
exactly one invalidation reason, and on `spring-boot-jar` the Boot one wins
even though build 1's configuration-cache report lists the Flow probes
(`./src/main/frontend`, `./src/main/frontend/index.ts`) as inputs as well —
so the exemption would convert a measurement that cannot be made into a green
scenario. It prints `WARN CC-FRESH inconclusive here …` instead, and the other
six projects carry that guard. Materialising `build/` first to stabilise the
Boot probe is not a way out: with `build/` intact `:vaadinBuildFrontend` is
UP-TO-DATE, nothing recreates `src/main/frontend`, and the reuse is vacuous —
the wiped `build/` is the scenario's premise.

`scripts/assert-cc.sh` parses the entry's fate out of a build log and can be
run standalone against a log downloaded from a failed CI run:

```bash
bash scripts/assert-cc.sh multimodule-jar/scenario-i-2.log REUSED
bash scripts/assert-cc.sh multimodule-jar/scenario-i-2.log NOT_REUSED "lib/build/libs/lib.jar"
```

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
# Cold mode: wipe ~/.gradle/caches/build-cache-1 and run scenarios A–I + R,
# once with the configuration cache off and once with it on (plus CC-FRESH).
bash scripts/run-project.sh --cache=cold plain-jar "$FLOW_VERSION"

# Just one pass — --cc=off is the historical build-cache-only run,
# --cc=on is the quick way to iterate on a configuration-cache bug.
bash scripts/run-project.sh --cache=cold --cc=off plain-jar "$FLOW_VERSION"
bash scripts/run-project.sh --cache=cold --cc=on  plain-jar "$FLOW_VERSION"

# Warm mode (default): leave the cache alone and assert that a
# clean build hits it. Requires the cache to be populated already.
bash scripts/run-project.sh plain-jar "$FLOW_VERSION"
```

### Run the whole suite

`scripts/run-suite.sh` drives `run-project.sh` over every project and
prints a per-project PASS/FAIL summary (exit non-zero if any failed):

```bash
# Run the full cold scenario set (A–I + R) for every project. This is the complete
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
for p in plain-jar war spring-boot-jar shaded-jar custom-jar-task custom-frontend-output multimodule-jar; do
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
# Cold suite (A–I plus R) with the key breakdown logged.
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
2. **`scenarios-cold`** — matrix over all 7 projects **× `cc: [off, on]`**,
   so 14 jobs. When building from source, each job downloads the Flow
   artifacts into mavenLocal; with `flow_version` set it skips that and
   lets Gradle resolve the published Flow. Each job runs
   `scripts/run-project.sh --cache=cold --cc=<leg>` (scenarios A–I plus
   the relocatability guard R, plus CC-FRESH on the `on` leg). Running the
   two passes as a matrix axis rather than sequentially keeps wall-clock
   unchanged, and a red `cc-on` leg against a green `cc-off` leg is the
   signature of a configuration-time input.

   Only the **`cc: off`** leg persists `~/.gradle/caches/build-cache-1`
   to the run-scoped Actions cache key. Both legs populate an equivalent
   cache, but the key is deliberately not scoped by `matrix.cc` — the warm
   job restores one key and must not have to pick a leg, and since Actions
   cache writes are write-once, letting both legs write would be a race
   whose winner decides what warm restores. A side benefit: a
   configuration-cache regression cannot starve the warm job.
3. **`scenarios-warm`** — `needs: scenarios-cold`, matrix over all 7
   projects. Each job restores the matching cold job's cache on a
   fresh runner and runs `scripts/run-project.sh --cache=warm`. A
   cache miss is a hard failure (`fail-on-cache-miss: true`) because
   the assertion is meaningless without a real restoration. Warm mode
   also runs one `--configuration-cache` build — the combination cold
   mode cannot reproduce, since a fresh runner has a populated build
   cache but no CC entry (entries live in the project's `.gradle/` and
   are never persisted across jobs).

Failed runs upload `cold-<project>-cc<off|on>-logs` /
`warm-<project>-logs` artifacts containing the Gradle logs **and** any
`configuration-cache-report.html` — the report names every CC problem and
the code that caused it, and is not a `*.log`, so it needs its own path.

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
│   ├── assert-task-outcome.sh
│   ├── assert-cc.sh
│   ├── addon-init.gradle              # scenario H: inject the add-on jar
│   └── file-dep-init.gradle           # scenario S: inject a files(...) dep
├── fixtures/
│   └── demo-addon/                    # scenario H's add-on (a @Route +
│                                      #   @JsModule); scenario S's marker
│                                      #   jar is generated into build/
├── plain-jar/                         # source-mode projects (com.vaadin.flow)
├── war/
├── spring-boot-jar/
├── shaded-jar/
├── custom-jar-task/
├── custom-frontend-output/
├── multimodule-jar/                   # the one multi-module project (:lib + :web)
└── platform/                          # published-mode mirrors (com.vaadin)
    ├── plain-jar/                     #   build.gradle + settings.gradle,
    ├── war/                           #   with src/ and the wrapper symlinked
    ├── spring-boot-jar/               #   back to the root project
    ├── shaded-jar/
    ├── custom-jar-task/
    ├── custom-frontend-output/
    └── multimodule-jar/               #   two modules, each with
                                       #   its own src/ symlink
```
