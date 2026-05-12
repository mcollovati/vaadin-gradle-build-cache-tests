package com.example;

import com.vaadin.flow.component.page.AppShellConfigurator;
import com.vaadin.flow.server.PWA;

@PWA(name = "Shaded JAR Demo", shortName = "ShadedJar")
public class Application implements AppShellConfigurator {

    public static void main(String[] args) {
        System.out.println("This is a build-cache test scaffold; no server is started.");
    }
}
