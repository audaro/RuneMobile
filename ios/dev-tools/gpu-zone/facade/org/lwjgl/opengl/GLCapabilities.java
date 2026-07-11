// Route C facade — only the members the base gpu plugin reads. On iOS these are computed from the EAGL GLES 3.0
// context (OpenGL33 must be satisfied by the bridge; see B1pt2 brief — the plugin aborts on !OpenGL33). The
// glXxx fields are function-pointer presence probes (plugin checks != 0); the bridge sets them per real support.
package org.lwjgl.opengl;
public class GLCapabilities {
	public boolean OpenGL31;
	public boolean OpenGL33;
	public boolean OpenGL40;
	public boolean OpenGL43;
	public boolean OpenGL45;
	public long glDebugMessageControl;            // KHR_debug — absent on Android GLES (0)
	public long glTexStorage3D;                   // core GLES 3.0 — present (non-0)
	public boolean GL_EXT_texture_filter_anisotropic;
	// RLHD reads these to choose between desktop-GL fast paths and GLES-core fallbacks. All FALSE on Android Zone:
	// persistent/storage buffers, indirect/multidraw, image load/store are gated off so RLHD takes the GLES-core
	// glBufferData / non-indirect / no-image paths the AG1b shader downport validated on real Mali.
	public boolean GL_ARB_buffer_storage;
	public boolean GL_ARB_copy_buffer;
	public boolean GL_ARB_map_buffer_range;
	public boolean GL_ARB_shader_image_load_store;
}
