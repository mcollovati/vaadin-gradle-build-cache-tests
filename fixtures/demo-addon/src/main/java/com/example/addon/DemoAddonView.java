package com.example.addon;

import com.vaadin.flow.component.dependency.JsModule;
import com.vaadin.flow.component.html.Div;
import com.vaadin.flow.router.Route;

/**
 * A routed view shipped inside the add-on jar. Flow discovers
 * {@code @Route} classes across the whole classpath, so merely putting
 * this jar on the application's classpath makes Flow collect the
 * {@link JsModule} below and stage the jar-bundled
 * demo-addon-marker.js into the production bundle — with no change to
 * the application's own sources. That is exactly what scenario H (#7)
 * needs: a frontend resource contributed by a dependency, isolated
 * from any main-classpath bytecode change.
 */
@Route("demo-addon")
@JsModule("./demo-addon-marker.js")
public class DemoAddonView extends Div {
}
