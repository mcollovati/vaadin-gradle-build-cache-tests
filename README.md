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

| Project           | Plugins                                                    | Task         | Archive layout                          | Expected outcome              |
|-------------------|------------------------------------------------------------|--------------|------------------------------------------|-------------------------------|
| `plain-jar`       | `java`, `application`, `com.vaadin.flow`                   | `build`      | `*.jar` (bundle at root)                 | Cache hits across scenarios   |
| `war`             | `war`, `com.vaadin.flow`                                   | `build`      | `*.war` (bundle at `WEB-INF/classes/`)   | Cache hits across scenarios   |
| `spring-boot-jar` | `org.springframework.boot`, `com.vaadin.flow`              | `bootJar`    | `*.jar` (bundle at `BOOT-INF/classes/`)  | Cache hits across scenarios   |
| `shaded-jar`      | `java`, `com.vaadin.flow`, `com.gradleup.shadow`           | `shadowJar`  | `*-all.jar`                              | Bundle **not** in archive     |
| `custom-jar-task` | `java`, `com.vaadin.flow` + a user-defined `Jar` task      | `customJar`  | `custom-jar.jar`                         | Bundle **not** in archive     |

The last two are documented limitations of the current plugin
(`isVaadinApplicationArchiveTask()` only recognises `jar`, `War`, and
`BootJar`). They are kept in the suite as negative tests so a future
plugin change that broadens archive-task detection will surface here.

## Scenarios (positive projects)

For each of `plain-jar`, `war`, and `spring-boot-jar`, the suite runs
four scenarios in order:

| # | Scenario              | Expected `vaadinBuildFrontend` outcome |
|---|-----------------------|----------------------------------------|
| A | Cold-cache restore: build → `rm -rf build/` → build | `SUCCESS` then `FROM-CACHE` |
| B | Add a test class then build with a clean output tree | `FROM-CACHE` |
| C | Edit `src/main/resources/application.properties` then build | `FROM-CACHE` |
| D | Modify the `@Route` view's Java code then build      | not from cache (re-executes) |

Scenario D is the negative assertion that proves the cache key is
sensitive to main-classpath bytecode changes — useful as a guard
against an over-eager future change that would weaken the cache
key.

## Running locally

### Prerequisites

- Java 21+ (Temurin recommended)
- Gradle 8.14+ on `PATH` (the projects do not ship a wrapper; CI sets
  Gradle up via `gradle/actions/setup-gradle`)
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
gradle clean build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
unzip -l build/libs/plain-jar.jar | grep META-INF/VAADIN/webapp/
```

Or run the scripted scenarios:

```bash
bash scripts/run-project.sh plain-jar "$FLOW_VERSION"
```

Per-project READMEs document the exact commands and expected outcomes
for each scenario.

### Run the whole suite

```bash
for p in plain-jar war spring-boot-jar shaded-jar custom-jar-task; do
  bash scripts/run-project.sh "$p" "$FLOW_VERSION"
done
```

### Wiping the build cache

The local Gradle build cache lives at
`$GRADLE_USER_HOME/caches/build-cache-1/` — default
`~/.gradle/caches/build-cache-1/`. Wipe it when you want to guarantee a
cold-cache run (for example, before re-validating that the suite still
catches the regression the PR fixes):

```bash
rm -rf "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/build-cache-1"
```

To bypass the cache for a single invocation without deleting it, add
`--no-build-cache` to the Gradle command line. Note that this affects
every Gradle project on the machine sharing the same `GRADLE_USER_HOME`,
so be deliberate.

## CI workflow

`.github/workflows/build-cache.yml` runs the same scenarios in CI. It
is triggered:

- Manually via `workflow_dispatch`, with inputs:
  - `flow_repo` (default `vaadin/flow`) — Flow repo (supports forks).
  - `flow_ref` (default `main`) — branch, tag, or SHA.
- Nightly at 02:00 UTC against `vaadin/flow@main`.

A matrix runs all five projects in parallel; each job installs the
specified Flow ref's plugin to its own `~/.m2/repository`, then runs
`scripts/run-project.sh`. Failed runs upload all `*.log` files for
inspection.

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
│   ├── run-project.sh
│   └── assert-task-outcome.sh
├── plain-jar/
├── war/
├── spring-boot-jar/
├── shaded-jar/
└── custom-jar-task/
```
