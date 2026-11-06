// Game audio output: the iOS half of HeadlessAudio's Sink. See RMGameAudio.m.
#import <Foundation/Foundation.h>

#include "jni/jni.h"

/// Binds HeadlessAudio's output natives. Call before the client boots; a jar without the class stays silent.
void RMGameAudioRegisterNatives(JNIEnv *env);
