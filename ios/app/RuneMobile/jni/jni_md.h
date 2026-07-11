/*
 * Machine-dependent JNI typedefs for arm64 Darwin (iOS). Standard OpenJDK
 * bsd/unix definitions — vendored because homebrew's openjdk@21 ships jmod-only
 * (no include/darwin/jni_md.h). ABI matches the bundled jre21 (aarch64 Darwin).
 */
#ifndef _JAVASOFT_JNI_MD_H_
#define _JAVASOFT_JNI_MD_H_

#define JNIEXPORT __attribute__((visibility("default")))
#define JNIIMPORT
#define JNICALL

typedef int jint;
typedef long long jlong;
typedef signed char jbyte;

#endif /* !_JAVASOFT_JNI_MD_H_ */
