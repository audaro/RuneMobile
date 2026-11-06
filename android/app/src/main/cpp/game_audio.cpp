// Game audio output. HeadlessAudio hands each started Java Sound line's ring to nOpen, and it plays through an AAudio
// stream of its own: the system mixes the streams and converts their rate (the engine writes 22050 Hz). The data
// callback runs on a real-time thread and only copies from the ring, so it never enters the VM.
//
// A stream dies when the output device changes (headphones, Bluetooth). AAudio reports that on its error callback,
// where the stream can't be closed, so a short-lived thread replaces it and the ring carries on where it was.
#include <aaudio/AAudio.h>
#include <android/log.h>
#include <jni.h>

#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "rm_audio_ring.h"

#define LOG_TAG "RuneMobile-audio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

struct Output {
    uint8_t *ring;
    uint32_t capacity;
    int32_t sampleRate;
    int32_t channels;
    AAudioStream *stream;
};

// Guards the map and every stream's open and close. The data callback takes no lock: an Output outlives its stream,
// and the error callback carries an id instead of a pointer so it can't outlive the Output.
std::mutex g_lock;
std::unordered_map<jlong, std::unique_ptr<Output>> g_outputs;
jlong g_nextId = 1;

aaudio_data_callback_result_t onData(AAudioStream *, void *user, void *data, int32_t frames) {
    auto *out = static_cast<Output *>(user);
    uint32_t wanted = static_cast<uint32_t>(frames) * static_cast<uint32_t>(out->channels) * sizeof(int16_t);
    uint32_t copied = rm_audio_ring_read(out->ring, out->capacity, data, wanted);
    memset(static_cast<uint8_t *>(data) + copied, 0, wanted - copied);
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

bool startStream(jlong id, Output &out);

void closeStream(Output &out) {
    if (out.stream) {
        AAudioStream_close(out.stream);
        out.stream = nullptr;
    }
}

void onError(AAudioStream *, void *user, aaudio_result_t error) {
    auto id = static_cast<jlong>(reinterpret_cast<intptr_t>(user));
    LOGI("output %lld lost: %s; replacing it", static_cast<long long>(id), AAudio_convertResultToText(error));
    std::thread([id] {
        std::lock_guard<std::mutex> hold(g_lock);
        auto found = g_outputs.find(id);
        if (found == g_outputs.end())
            return; // the line closed first
        closeStream(*found->second);
        startStream(id, *found->second); // on failure the engine sees no progress and reopens the line
    }).detach();
}

bool startStream(jlong id, Output &out) {
    AAudioStreamBuilder *builder = nullptr;
    aaudio_result_t result = AAudio_createStreamBuilder(&builder);
    if (result != AAUDIO_OK) {
        LOGE("createStreamBuilder: %s", AAudio_convertResultToText(result));
        return false;
    }
    AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setSampleRate(builder, out.sampleRate);
    AAudioStreamBuilder_setChannelCount(builder, out.channels);
    // The engine already buffers ahead, so spend nothing on the low-latency path.
    AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_NONE);
    AAudioStreamBuilder_setUsage(builder, AAUDIO_USAGE_GAME);
    AAudioStreamBuilder_setContentType(builder, AAUDIO_CONTENT_TYPE_SONIFICATION);
    AAudioStreamBuilder_setDataCallback(builder, onData, &out);
    AAudioStreamBuilder_setErrorCallback(builder, onError, reinterpret_cast<void *>(static_cast<intptr_t>(id)));
    result = AAudioStreamBuilder_openStream(builder, &out.stream);
    AAudioStreamBuilder_delete(builder);
    if (result == AAUDIO_OK)
        result = AAudioStream_requestStart(out.stream);
    if (result != AAUDIO_OK) {
        LOGE("start %d Hz %dch: %s", out.sampleRate, out.channels, AAudio_convertResultToText(result));
        closeStream(out);
        return false;
    }
    LOGI("output %lld: %d Hz %dch, %d-frame bursts", static_cast<long long>(id), AAudioStream_getSampleRate(out.stream),
         AAudioStream_getChannelCount(out.stream), AAudioStream_getFramesPerBurst(out.stream));
    return true;
}

jlong JNICALL nOpen(JNIEnv *env, jclass, jobject ring, jint capacity, jint sampleRate, jint channels) {
    auto *address = static_cast<uint8_t *>(env->GetDirectBufferAddress(ring));
    if (!address)
        return 0;
    auto out = std::make_unique<Output>(Output{address, static_cast<uint32_t>(capacity), sampleRate, channels, nullptr});
    std::lock_guard<std::mutex> hold(g_lock);
    jlong id = g_nextId++;
    if (!startStream(id, *out))
        return 0;
    g_outputs.emplace(id, std::move(out));
    return id;
}

void JNICALL nClose(JNIEnv *, jclass, jlong handle) {
    std::lock_guard<std::mutex> hold(g_lock);
    auto found = g_outputs.find(handle);
    if (found == g_outputs.end())
        return;
    closeStream(*found->second); // the data callback has stopped once this returns, so the ring is the line's again
    g_outputs.erase(found);
}

const JNINativeMethod kMethods[] = {
    {const_cast<char *>("nOpen"), const_cast<char *>("(Ljava/nio/ByteBuffer;III)J"), reinterpret_cast<void *>(nOpen)},
    {const_cast<char *>("nClose"), const_cast<char *>("(J)V"), reinterpret_cast<void *>(nClose)},
};

} // namespace

void registerGameAudioNatives(JNIEnv *env) {
    jclass audio = env->FindClass("net/runelite/client/headless/HeadlessAudio");
    if (!audio || env->RegisterNatives(audio, kMethods, sizeof(kMethods) / sizeof(kMethods[0])) != JNI_OK) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        LOGE("no game audio: HeadlessAudio natives did not register");
    }
    if (audio)
        env->DeleteLocalRef(audio);
}
