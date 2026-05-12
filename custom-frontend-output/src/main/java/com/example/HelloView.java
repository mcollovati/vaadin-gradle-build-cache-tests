package com.example;

import com.vaadin.flow.component.html.Div;
import com.vaadin.flow.component.html.H1;
import com.vaadin.flow.component.html.Paragraph;
import com.vaadin.flow.router.Route;

@Route("")
public class HelloView extends Div {

    public HelloView() {
        add(new H1("Hello, Vaadin!"));
        add(new Paragraph("Welcome to the build-cache test scaffold."));
    }
}
