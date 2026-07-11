// Route C facade — only the members the base gpu plugin reads. On iOS these are computed from the EAGL GLES 3.0
// context (OpenGL33 must be satisfied by the bridge; see B1pt2 brief — the plugin aborts on !OpenGL33). The
// glXxx fields are function-pointer presence probes (plugin checks != 0); the bridge sets them per real support.
package org.lwjgl.opengl;
public class GLCapabilities {
	public boolean OpenGL33;
	public boolean OpenGL45;
	public long glDebugMessageControl;            // KHR_debug — absent on iOS GLES (0)
	public long glTexStorage3D;                   // core GLES 3.0 — present (non-0)
	public boolean GL_EXT_texture_filter_anisotropic;
}
