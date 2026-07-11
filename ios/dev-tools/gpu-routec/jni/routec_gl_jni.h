/* Route C — JNI GL bridge registration entry point (implemented in routec_gl_jni.m). Call once after
   JNI_CreateJavaVM, before the gpu plugin (or the L1 probe) runs, with the facade classes on the classpath.
   Returns JNI_OK (0) on success; JNI_ERR (<0) if the facade classes aren't found (e.g. a non-Route-C boot). */
#ifndef ROUTEC_GL_JNI_H
#define ROUTEC_GL_JNI_H
#include <jni.h>
jint RouteC_registerGLNatives(JNIEnv *env);
#endif
