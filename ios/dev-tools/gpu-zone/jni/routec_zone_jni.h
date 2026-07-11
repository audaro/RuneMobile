/*
 * GPU Zone B0.2/B0.3 — RLHD (117HD) JNI delta bridge registration entry point. Companion to
 * ../../gpu-routec/jni/routec_gl_jni.h. Call AFTER RouteC_registerGLNatives (the base bridge) when booting
 * in zone mode: both register disjoint native sets on org/lwjgl/opengl/GLALL (+ MemoryUtil). Returns 0 on success.
 */
#ifndef ROUTEC_ZONE_JNI_H
#define ROUTEC_ZONE_JNI_H
#include <jni.h>
jint RouteC_registerZoneNatives(JNIEnv *env);
#endif
