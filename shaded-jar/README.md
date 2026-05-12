# shaded-jar (negative test)

Standalone Gradle project applying `com.gradleup.shadow` alongside the
Flow plugin. This is a **documented limitation** of the current Flow
Gradle plugin: `isVaadinApplicationArchiveTask()` only recognises the
canonical `jar` task, the `War` type, and Spring Boot's `BootJar`.
Shadow's `shadowJar` task is a `Jar` subclass with a different name, so
the plugin does **not** automatically wire the Vaadin frontend bundle
into it.

The expected behaviour from this project is that **the produced shaded
archive does NOT contain `META-INF/VAADIN/webapp/...`**. The suite
keeps the project around as a guard: if a future plugin change extends
archive-task detection (e.g. to handle `ShadowJar`), the negative
assertion here will start failing and call attention to that change.

## Prerequisites

- Java 21+ (Temurin recommended)
- Gradle 8.14+ on `PATH`
- Node.js 22+
- Flow plugin and `com.vaadin:flow` artifact installed locally:

  ```bash
  ./mvnw -B -DskipTests -am -pl flow-plugins/flow-gradle-plugin install
  FLOW_VERSION=$(./mvnw -q help:evaluate -Dexpression=project.version -DforceStdout)
  ```

## Quick start

```bash
gradle clean shadowJar --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
```

Expected outcome:

- The build **succeeds**.
- `build/libs/shaded-jar-all.jar` is produced.
- The archive does **not** contain `META-INF/VAADIN/webapp/`. Verify:

  ```bash
  unzip -l build/libs/shaded-jar-all.jar | grep META-INF/VAADIN/webapp || echo "OK: bundle absent"
  ```

## Workaround for end users

If you need the Vaadin bundle inside a `shadowJar`, wire it manually:

```groovy
tasks.named('shadowJar') {
    dependsOn 'vaadinBuildFrontend'
    from(layout.buildDirectory.dir('vaadin-build-frontend'))
}
```

This is intentionally not part of the test project because the goal of
the suite is to document the **default plugin behaviour**, not to
provide a workaround.

## Wiping the build cache

To force a cold cache before re-running the build:

```bash
rm -rf "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/build-cache-1"
```

Or bypass the cache for a single invocation without deleting it:

```bash
gradle shadowJar --no-build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
```

The first form affects every Gradle project on the machine using the
same `GRADLE_USER_HOME`.

## One-shot scripted run

```bash
bash scripts/run-project.sh shaded-jar "$FLOW_VERSION"
```

The script runs a single build and asserts the archive does not
contain the bundle.
