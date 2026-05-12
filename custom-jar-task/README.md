# custom-jar-task (negative test)

Standalone Gradle project that defines a user-supplied `Jar` task
(`customJar`). This is a **documented limitation** of the current Flow
Gradle plugin: `isVaadinApplicationArchiveTask()` only treats the
canonical `jar` task (matched by name) plus `War` and `BootJar` (matched
by class) as Vaadin application archives. A user-defined `Jar` task with
a different name is **not** automatically wired to depend on
`vaadinBuildFrontend`, and the produced archive does **not** contain the
Vaadin frontend bundle.

The project is kept in the suite to catch any future plugin change that
broadens archive-task detection — the negative assertion below will
start failing and surface the change.

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
gradle clean customJar --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
```

Expected outcome:

- The build **succeeds**.
- `build/libs/custom-jar.jar` is produced.
- The archive does **not** contain `META-INF/VAADIN/webapp/`. Verify:

  ```bash
  unzip -l build/libs/custom-jar.jar | grep META-INF/VAADIN/webapp || echo "OK: bundle absent"
  ```

## Workaround for end users

If you need the Vaadin bundle inside a custom `Jar` task, wire it
manually:

```groovy
tasks.register('customJar', Jar) {
    archiveBaseName = 'custom-jar'
    from sourceSets.main.output
    dependsOn 'vaadinBuildFrontend'
    from(layout.buildDirectory.dir('vaadin-build-frontend'))
}
```

This is intentionally not part of the test project because the goal of
the suite is to document the **default plugin behaviour**.

## Wiping the build cache

To force a cold cache before re-running the build:

```bash
rm -rf "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/build-cache-1"
```

Or bypass the cache for a single invocation without deleting it:

```bash
gradle customJar --no-build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
```

The first form affects every Gradle project on the machine using the
same `GRADLE_USER_HOME`.

## One-shot scripted run

```bash
bash scripts/run-project.sh custom-jar-task "$FLOW_VERSION"
```
