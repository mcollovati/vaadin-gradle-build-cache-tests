# plain-jar

Standalone Gradle project applying the `java` + `application` + `com.vaadin.flow`
plugins. Validates that `vaadinBuildFrontend` outputs are correctly cached
and that the produced plain JAR contains the Vaadin bundle at the archive
root (`META-INF/VAADIN/webapp/...`).

## Prerequisites

- Java 21+ (Temurin recommended)
- Gradle 8.14+ on `PATH`
- Node.js 22+
- The Flow plugin and `com.vaadin:flow` artifact installed to your local
  Maven repository. From a Flow checkout:

  ```bash
  ./mvnw -B -DskipTests -am -pl flow-plugins/flow-gradle-plugin install
  FLOW_VERSION=$(./mvnw -q help:evaluate -Dexpression=project.version -DforceStdout)
  ```

## Quick start

```bash
gradle clean build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
```

Expected outcome:

- `:vaadinBuildFrontend` runs and produces `build/vaadin-build-frontend/`.
- `build/libs/plain-jar.jar` exists and contains
  `META-INF/VAADIN/webapp/VAADIN/build/...` (verify with
  `unzip -l build/libs/plain-jar.jar | grep META-INF/VAADIN`).
- Exactly one `META-INF/VAADIN/config/flow-build-info.json` entry.

## Cache behaviour checks

Run each scenario in order from the project root.

### Scenario A — Cold-cache restore

```bash
gradle clean build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
# Expect: > Task :vaadinBuildFrontend       (no suffix == SUCCESS)

rm -rf build/

gradle build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
# Expect: > Task :vaadinBuildFrontend FROM-CACHE
```

### Scenario B — Add a test class

The cache key only fingerprints `output.classesDirs` of the main source
set, so adding a test class must not invalidate it.

```bash
rm -rf build/
cat > src/test/java/com/example/AddedTest.java <<'EOF'
package com.example;

import org.junit.jupiter.api.Test;

public class AddedTest {
    @Test
    public void shouldCompile() {}
}
EOF

gradle build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
# Expect: > Task :vaadinBuildFrontend FROM-CACHE

rm src/test/java/com/example/AddedTest.java
```

### Scenario C — Edit a resource file

`src/main/resources/...` is not on the classpath input fingerprint, so
edits there must not invalidate the cache.

```bash
rm -rf build/
echo "# scenario C marker $(date -u +%s)" >> src/main/resources/application.properties

gradle build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
# Expect: > Task :vaadinBuildFrontend FROM-CACHE

git checkout src/main/resources/application.properties
```

### Scenario D — Modify the @Route view

Changing main-source bytecode (e.g. a string literal in `HelloView`)
must cause the cache key to shift and `vaadinBuildFrontend` to
re-execute.

```bash
rm -rf build/
sed -i 's/Hello, Vaadin!/Hello, Vaadin (edited)!/' src/main/java/com/example/HelloView.java

gradle build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
# Expect: > Task :vaadinBuildFrontend            (NO FROM-CACHE suffix)

git checkout src/main/java/com/example/HelloView.java
```

The produced archive still contains the bundle in every scenario.

## Wiping the build cache

To force a cold cache before re-running scenario A:

```bash
rm -rf "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/build-cache-1"
```

Or bypass the cache for a single invocation without deleting it:

```bash
gradle build --no-build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
```

The first form affects every Gradle project on the machine using the
same `GRADLE_USER_HOME`.

## One-shot scripted run

From the repository root:

```bash
bash scripts/run-project.sh plain-jar "$FLOW_VERSION"
```

The script runs all four scenarios and parses the gradle log to assert
the expected `vaadinBuildFrontend` outcome at each step.
