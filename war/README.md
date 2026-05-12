# war

Standalone Gradle project applying the `war` + `com.vaadin.flow` plugins.
Validates that `vaadinBuildFrontend` outputs are correctly cached and
that the produced WAR contains the Vaadin bundle at
`WEB-INF/classes/META-INF/VAADIN/webapp/...`.

## Prerequisites

- Java 21+ (Temurin recommended)
- Gradle: not needed on `PATH` — this project ships a wrapper (`./gradlew`)
- Node.js 22+
- Flow plugin and `com.vaadin:flow` artifact installed locally:

  ```bash
  ./mvnw -B -DskipTests -am -pl flow-plugins/flow-gradle-plugin install
  FLOW_VERSION=$(./mvnw -q help:evaluate -Dexpression=project.version -DforceStdout)
  ```

## Quick start

```bash
./gradlew clean build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
```

Expected outcome:

- `:vaadinBuildFrontend` runs and produces `build/vaadin-build-frontend/`.
- `build/libs/war.war` exists and contains
  `WEB-INF/classes/META-INF/VAADIN/webapp/VAADIN/build/...`.
- Verify with:
  ```bash
  unzip -l build/libs/war.war | grep META-INF/VAADIN
  ```

## Cache behaviour checks

### Scenario A — Cold-cache restore

```bash
./gradlew clean build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
# Expect: > Task :vaadinBuildFrontend

rm -rf build/
./gradlew build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
# Expect: > Task :vaadinBuildFrontend FROM-CACHE
```

### Scenario B — Add a test class

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

./gradlew build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
# Expect: > Task :vaadinBuildFrontend FROM-CACHE

rm src/test/java/com/example/AddedTest.java
```

### Scenario C — Edit a resource file

```bash
rm -rf build/
echo "# scenario C marker $(date -u +%s)" >> src/main/resources/application.properties

./gradlew build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
# Expect: > Task :vaadinBuildFrontend FROM-CACHE

git checkout src/main/resources/application.properties
```

### Scenario D — Modify the @Route view

```bash
rm -rf build/
sed -i 's/Hello, Vaadin!/Hello, Vaadin (edited)!/' src/main/java/com/example/HelloView.java

./gradlew build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
# Expect: > Task :vaadinBuildFrontend       (NO FROM-CACHE suffix)

git checkout src/main/java/com/example/HelloView.java
```

## Wiping the build cache

To force a cold cache before re-running scenario A:

```bash
rm -rf "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/build-cache-1"
```

Or bypass the cache for a single invocation without deleting it:

```bash
./gradlew build --no-build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
```

The first form affects every Gradle project on the machine using the
same `GRADLE_USER_HOME`.

## One-shot scripted run

```bash
bash scripts/run-project.sh war "$FLOW_VERSION"
```
