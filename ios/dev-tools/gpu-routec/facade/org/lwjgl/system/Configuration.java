package org.lwjgl.system;
public class Configuration<T> {
	public static final Configuration<String> SHARED_LIBRARY_EXTRACT_DIRECTORY = new Configuration<>();
	public Configuration<T> set(T value) { return this; }
	public T get() { return null; }
}
