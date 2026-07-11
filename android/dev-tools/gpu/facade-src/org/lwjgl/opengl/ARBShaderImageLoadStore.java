// Facade shim for org.lwjgl.opengl.ARBShaderImageLoadStore — RLHD reads GL_MAX_IMAGE_UNITS (inherited from GLALL);
// the image-load/store path is gated OFF via GLCapabilities.GL_ARB_shader_image_load_store=false on Zone.
package org.lwjgl.opengl;
public class ARBShaderImageLoadStore extends GLALL {}
