// The native half of HeadlessAudioLine's ring, included by both ports. The layout is documented on that class:
// a change to one side has to change the other, in the same commit.
#ifndef RM_AUDIO_RING_H
#define RM_AUDIO_RING_H

#include <stdint.h>
#include <string.h>

enum { RM_AUDIO_WRITE_POS = 0,
       RM_AUDIO_READ_POS = 8,
       RM_AUDIO_FLUSH_POS = 16,
       RM_AUDIO_DATA = 64 };

// Copies up to `bytes` of samples into `dst` and returns how many there were. Safe on a real-time audio thread:
// it takes no locks, allocates nothing, and never enters the VM.
static inline uint32_t rm_audio_ring_read(uint8_t *ring, uint32_t capacity, void *dst, uint32_t bytes) {
    int64_t *readPos = (int64_t *)(ring + RM_AUDIO_READ_POS);
    int64_t read = __atomic_load_n(readPos, __ATOMIC_RELAXED);
    int64_t flush = __atomic_load_n((int64_t *)(ring + RM_AUDIO_FLUSH_POS), __ATOMIC_ACQUIRE);
    int64_t write = __atomic_load_n((int64_t *)(ring + RM_AUDIO_WRITE_POS), __ATOMIC_ACQUIRE);
    if (flush > read)
        read = flush;
    int64_t ready = write - read;
    uint32_t count = ready < (int64_t)bytes ? (uint32_t)ready : bytes;
    uint32_t at = (uint32_t)(read % capacity);
    uint32_t first = capacity - at < count ? capacity - at : count;
    memcpy(dst, ring + RM_AUDIO_DATA + at, first);
    memcpy((uint8_t *)dst + first, ring + RM_AUDIO_DATA, count - first);
    __atomic_store_n(readPos, read + count, __ATOMIC_RELEASE);
    return count;
}

#endif
