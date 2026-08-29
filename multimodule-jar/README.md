# multimodule-jar

The only multi-module project in the suite. `:lib` is a plain Java
library; `:web` applies `java` + `application` + `com.vaadin.flow` and
declares `implementation project(':lib')`. Everything else — sources,
archive shape, expected in-archive layout — mirrors `../plain-jar`.

## Why it exists

`:web:vaadinBuildFrontend` has a jar produced by *another module* on its
runtime classpath. On a cold build that jar does not exist yet when
Gradle snapshots the task's inputs, and the Flow plugin folds the
dependency jars into a `dependencyJarFingerprint` scalar input. If that
fingerprint is derived from a provider that does not carry the file
collection's task dependencies, the value differs between the cold build
and the very next identical one — two cache keys for one unchanged
source tree, and `UP-TO-DATE` only on the third build.

That is [vaadin/flow#25387](https://github.com/vaadin/flow/issues/25387),
and scenario I in `scripts/run-project.sh` is the guard: two identical
builds back to back, the second of which must be `UP-TO-DATE`.

**The bug only reproduces under Gradle's configuration cache.** Measured
on this fixture against Vaadin 25.2.6:

| | build 1 | build 2 | build 3 |
|---|---|---|---|
| plain `--build-cache` | `SUCCESS` | `UP-TO-DATE` | `UP-TO-DATE` |
| `+ --configuration-cache` | `SUCCESS`, entry stored | **re-executes**, entry stored again | `UP-TO-DATE`, entry reused |

Gradle names the culprit on that second build: `configuration cache cannot
be reused because file 'lib/build/libs/lib.jar' has changed`. That is why
cold mode runs the whole scenario set twice — once with the configuration
cache off, once with it on (`--cc=off|on|both`, default both). Scenario I's
copy in the CC pass is the #25387 guard: it asserts the first build
**stored** an entry and the second **reused** it. Its CC-off copy is only a
cheap sanity check, since a broken plugin passes it.

A `cc_reset` runs before scenario I's first build, and it is load-bearing
rather than hygiene: if that build reused the entry scenario A left behind,
the dependency-jar fingerprint would never be recomputed — the task graph
would simply be deserialized — and the bug would be masked instead of
exposed. Before the CC pass existed, scenario I's first build did exactly
that (its log opened with `Reusing configuration cache.`), which made its
"two identical builds" really the run's third and fourth.

Note that the *third* build is `UP-TO-DATE` even on the broken plugin, so
an assertion placed one build later would pass on a regression.

The fix in [vaadin/flow#25388](https://github.com/vaadin/flow/pull/25388)
(deriving the fingerprint from `dependencyJarFiles.elements` instead of a
standalone `project.provider`) was verified against this fixture: build 2
becomes `UP-TO-DATE` with its configuration-cache entry reused, and
`dependencyJarFingerprint` holds a single value across every build
instead of flipping between two.

Two further observations from validating this fixture, both against
plugins that still carry the bug (Vaadin 25.2.6 and Flow 25.3-SNAPSHOT):

- `--cache-debug` isolates the cause to a single line —
  `dependencyJarFingerprint$com_vaadin_flow_gradle_plugin` is the only
  input that differs between the two builds, and it alone moves the
  task's cache key.
- Scenario A part 2 has been seen to miss the cache intermittently here
  (`expected FROM-CACHE, got SUCCESS`) while passing on repeat runs. The
  same fingerprint is the plausible cause — the provider is evaluated
  without a declared dependency on the jar it reads, so its evaluation
  order relative to `:lib:jar` is not guaranteed — but this has not been
  pinned down. If it recurs on a plugin that *has* the fix, investigate
  rather than assuming it is known flakiness.

## Layout

```
multimodule-jar/
├── settings.gradle          # include 'lib', 'web'
├── build.gradle             # empty root
├── lib/
│   ├── build.gradle         # plain java, no Vaadin
│   └── src/main/java/com/example/lib/LibraryGreeter.java
└── web/
    ├── build.gradle         # java + application + com.vaadin.flow
    └── src/                 # the standard fixture layout
```

`HelloView` calls into `LibraryGreeter`, so the project dependency is a
real compile-and-runtime edge rather than an unused declaration.

## Quick start

```bash
./gradlew clean :web:build --build-cache --console=plain \
  -Pvaadin.productionMode -PflowVersion="$FLOW_VERSION"
```

Expected outcome:

- `:web:vaadinBuildFrontend` runs and produces `web/build/vaadin-build-frontend/`.
- `web/build/libs/web.jar` exists and contains `META-INF/VAADIN/webapp/...`
  at the archive root.
- An immediately repeated invocation reports
  `> Task :web:vaadinBuildFrontend UP-TO-DATE`. Add `--configuration-cache`
  to both invocations to see the #25387 regression: on a broken plugin the
  second build re-executes and Gradle re-stores its configuration-cache
  entry.

**Create `web/src/main/frontend` before the first build** when reproducing
by hand. That directory is gitignored, so a fresh checkout does not have it
and the first build creates it — which on its own makes the second build
refuse to reuse the entry, for the unrelated reason `the file system entry
'web/src/main/frontend' has been created`. Mistaking that for #25387 costs
an afternoon. The scripted run covers this case deliberately as scenario
CC-FRESH, which is why CC-FRESH and scenario I are kept separate: CC-FRESH
red with scenario I green isolates the frontend-directory probe, both red
means #25387 as well.

## Scripted run

From the repository root:

```bash
bash scripts/run-project.sh --cache=cold multimodule-jar "$FLOW_VERSION"
```
