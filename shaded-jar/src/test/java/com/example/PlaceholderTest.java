package com.example;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

public class PlaceholderTest {

    @Test
    public void greet() {
        assertEquals("Hello, World!", new PlainService().greet("World"));
    }
}
