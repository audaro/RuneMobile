// Game audio output. HeadlessAudio hands each started Java Sound line's ring to nOpen, and it plays through a source
// node on an AVAudioEngine of its own. The mixer converts the rate (the engine writes 22050 Hz). The render block runs
// on a real-time thread and only copies from the ring, so it never enters the VM.
//
// This engine is deliberately not the keepalive's. The keepalive decides whether the process stays resident, and it
// has to survive whatever happens to the game's audio, so all the two share is the session: the same mixable playback
// category, which is why game audio plays over the player's own music. Nothing here deactivates the session.
//
// It stops when no line is playing, which includes everything behind the app: HeadlessAudio closes its outputs in the
// background, so this engine can't keep a process alive after the keepalive's idle gate has released it.
#import "RMGameAudio.h"

#import <AVFoundation/AVFoundation.h>

#include <stdatomic.h>
#include <unistd.h>

#include "rm_audio_ring.h"

// Lets a close know the render block has finished with a ring. A node detached from a running engine isn't documented
// to stop rendering by the time the call returns, and Java owns that memory again once nClose does. Stopping the
// engine would guarantee it too, but would cut every other line's audio each time a plugin's clip ended.
typedef struct {
    atomic_int rendering;
    atomic_int closing;
} RMRenderGate;

// Frames converted at a time. The render block has no heap to reach for, so this is on its stack.
enum { kRenderChunkFrames = 512 };

@interface RMGameAudioOutput : NSObject
@property (nonatomic) uint8_t *ring;
@property (nonatomic) uint32_t capacity;
@property (nonatomic) double sampleRate;
@property (nonatomic) uint32_t channels;
@property (nonatomic) AVAudioSourceNode *node;
@property (nonatomic) NSMutableData *gate; // an RMRenderGate; the node's block keeps it alive for as long as it can run
@end

@implementation RMGameAudioOutput
@end

// Everything below runs on gQueue, which is what serializes the engine's graph changes. Java blocks on it through
// dispatch_sync, and no block on it ever calls back into Java.
static dispatch_queue_t gQueue;
static AVAudioEngine *gEngine;
static NSMutableDictionary<NSNumber *, RMGameAudioOutput *> *gOutputs;
static jlong gNextId = 1;

static AVAudioSourceNode *newSourceNode(RMGameAudioOutput *output) {
    uint8_t *ring = output.ring;
    uint32_t capacity = output.capacity;
    uint32_t channels = output.channels;
    uint32_t frameBytes = channels * sizeof(int16_t);
    NSMutableData *gateStorage = [NSMutableData dataWithLength:sizeof(RMRenderGate)];
    RMRenderGate *gate = gateStorage.mutableBytes;
    output.gate = gateStorage;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:output.sampleRate
                                                                           channels:channels];
    return [[AVAudioSourceNode alloc]
        initWithFormat:format
           renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *time, AVAudioFrameCount frames,
                                 AudioBufferList *out) {
               (void)gateStorage;
               int16_t chunk[kRenderChunkFrames * 2];
               uint32_t done = 0;
               atomic_store(&gate->rendering, 1);
               while (done < frames && !atomic_load(&gate->closing)) {
                   uint32_t wanted = MIN(frames - done, (uint32_t)kRenderChunkFrames);
                   uint32_t got = rm_audio_ring_read(ring, capacity, chunk, wanted * frameBytes) / frameBytes;
                   for (uint32_t channel = 0; channel < channels; channel++) {
                       float *samples = (float *)out->mBuffers[channel].mData + done;
                       for (uint32_t i = 0; i < got; i++)
                           samples[i] = chunk[i * channels + channel] / 32768.0f;
                   }
                   done += got;
                   if (got < wanted)
                       break;
               }
               atomic_store(&gate->rendering, 0);
               for (uint32_t channel = 0; channel < channels; channel++) {
                   float *samples = (float *)out->mBuffers[channel].mData;
                   memset(samples + done, 0, (frames - done) * sizeof(float));
               }
               return noErr;
           }];
}

// The keepalive normally set this long ago. If it failed, game audio mustn't take the default category, which stops
// the player's music and goes quiet at the Ring/Silent setting without saying why.
static void ensureSession(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayback]) {
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:nil];
    }
    [session setActive:YES error:nil];
}

static BOOL startEngine(void) {
    if (gEngine.isRunning)
        return YES;
    ensureSession();
    NSError *error = nil;
    BOOL started = NO;
    @try { // engine wiring reports its failures as exceptions
        [gEngine prepare];
        started = [gEngine startAndReturnError:&error];
    } @catch (NSException *exception) {
        fprintf(stderr, "[audio] engine start threw: %s\n", exception.reason.UTF8String);
        return NO;
    }
    if (!started)
        fprintf(stderr, "[audio] engine start failed: %s\n", error.localizedDescription.UTF8String);
    return started;
}

static BOOL attachOutput(RMGameAudioOutput *output) {
    @try {
        output.node = newSourceNode(output);
        [gEngine attachNode:output.node];
        [gEngine connect:output.node
                      to:gEngine.mainMixerNode
                  format:[output.node outputFormatForBus:0]];
        return YES;
    } @catch (NSException *exception) {
        fprintf(stderr, "[audio] attach threw: %s\n", exception.reason.UTF8String);
        output.node = nil;
        return NO;
    }
}

// After this the output's render block can't touch its ring again, whatever the engine does with the node.
static void closeGate(RMGameAudioOutput *output) {
    if (!output.gate)
        return;
    RMRenderGate *gate = output.gate.mutableBytes;
    atomic_store(&gate->closing, 1);
    while (atomic_load(&gate->rendering))
        usleep(100); // one render's copy, so a matter of microseconds
}

static void detachOutput(RMGameAudioOutput *output) {
    if (output.node) {
        closeGate(output);
        [gEngine disconnectNodeOutput:output.node];
        [gEngine detachNode:output.node];
        output.node = nil;
    }
    if (gOutputs.count == 0)
        [gEngine stop];
}

static void resumeIfWanted(void) {
    if (gOutputs.count > 0)
        startEngine();
}

// A media-services reset leaves the engine and its nodes as dead objects, so they are built again from the rings.
static void rebuildEngine(void) {
    for (RMGameAudioOutput *output in gOutputs.allValues)
        closeGate(output);
    gEngine = [[AVAudioEngine alloc] init];
    for (RMGameAudioOutput *output in gOutputs.allValues)
        attachOutput(output);
    resumeIfWanted();
}

static jlong JNICALL nOpen(JNIEnv *env, jclass cls, jobject ring, jint capacity, jint sampleRate, jint channels) {
    uint8_t *address = (*env)->GetDirectBufferAddress(env, ring);
    if (!address)
        return 0;
    RMGameAudioOutput *output = [[RMGameAudioOutput alloc] init];
    output.ring = address;
    output.capacity = (uint32_t)capacity;
    output.sampleRate = sampleRate;
    output.channels = (uint32_t)channels;
    __block jlong handle = 0;
    dispatch_sync(gQueue, ^{
        // Nodes connect upstream of a running mixer, so the lines already playing carry on undisturbed.
        BOOL attached = attachOutput(output);
        if (attached && startEngine()) {
            handle = gNextId++;
            gOutputs[@(handle)] = output;
        } else if (attached) {
            detachOutput(output); // HeadlessAudioLine tries again in a couple of seconds
        }
    });
    return handle;
}

static void JNICALL nClose(JNIEnv *env, jclass cls, jlong handle) {
    if (handle == 0)
        return;
    dispatch_sync(gQueue, ^{
        RMGameAudioOutput *output = gOutputs[@(handle)];
        if (!output)
            return;
        [gOutputs removeObjectForKey:@(handle)];
        detachOutput(output);
    });
}

static void observeSession(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    void (^resume)(NSNotification *) = ^(NSNotification *note) {
        dispatch_async(gQueue, ^{
            resumeIfWanted();
        });
    };
    // A route change reconfigures the engine, and it comes back stopped. Headphones and Bluetooth land here.
    [center addObserverForName:AVAudioEngineConfigurationChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:resume];
    // A call or Siri stops it too; the session says when they are done.
    [center addObserverForName:AVAudioSessionInterruptionNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
                        NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                        if (type == AVAudioSessionInterruptionTypeEnded)
                            resume(note);
                    }];
    [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
                        dispatch_async(gQueue, ^{
                            rebuildEngine();
                        });
                    }];
}

void RMGameAudioRegisterNatives(JNIEnv *env) {
    static const JNINativeMethod methods[] = {
        {"nOpen", "(Ljava/nio/ByteBuffer;III)J", (void *)nOpen},
        {"nClose", "(J)V", (void *)nClose},
    };
    jclass audio = (*env)->FindClass(env, "net/runelite/client/headless/HeadlessAudio");
    if (!audio || (*env)->RegisterNatives(env, audio, methods, 2) != JNI_OK) {
        (*env)->ExceptionClear(env);
        fprintf(stderr, "[audio] HeadlessAudio natives did not register: no game audio\n");
        return;
    }
    (*env)->DeleteLocalRef(env, audio);
    gQueue = dispatch_queue_create("rm.game-audio", DISPATCH_QUEUE_SERIAL);
    gEngine = [[AVAudioEngine alloc] init];
    gOutputs = [NSMutableDictionary dictionary];
    observeSession();
}
