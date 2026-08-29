package com.example;

import com.example.lib.LibraryGreeter;
import com.vaadin.flow.component.html.Div;
import com.vaadin.flow.component.html.H1;
import com.vaadin.flow.component.html.Paragraph;
import com.vaadin.flow.router.Route;

@Route("")
public class HelloView extends Div {

    public HelloView() {
        add(new H1("Hello, Vaadin!"));
        // Reads from the ':lib' module so the project dependency is a real
        // compile-and-runtime edge, not just a declaration in build.gradle.
        add(new Paragraph(new LibraryGreeter().subtitle()));
    }
}
