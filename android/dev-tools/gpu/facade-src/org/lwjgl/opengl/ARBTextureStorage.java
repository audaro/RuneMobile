// Facade shim for org.lwjgl.opengl.ARBTextureStorage — RLHD's MaterialManager calls glTexStorage3D through it
// (immutable texture-array allocation; GLES 3.0 core, inherited from GLALL).
package org.lwjgl.opengl;
public class ARBTextureStorage extends GLALL {}
