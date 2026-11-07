// What the process's memory was made of, a line a minute, kept for the next launch's Share logs.
//
// iOS kills a process over its memory limit with no notice, so all that can ever be known about such a death is what
// was written down before it. RMResidency keeps the headroom, which says a session ran out and not what filled it, and
// memWatchdog's lines only exist in a Debug build or with the perf probe armed. A player's phone gets this instead, so
// a report after a memory kill shows which of these climbed:
//   fp      phys_footprint, the number the limit applies to
//   free    os_proc_available_memory, the headroom to that limit (always 0 in the simulator)
//   gfx     graphics memory: GL and Metal buffers and textures, IOSurfaces
//   media   memory tagged for media: decoded video and its pools
//   malloc  everything live in the malloc zones, ours, the JVM's and the system frameworks'
//   heap    Java heap, used/committed
//   threads every thread in the process
// All in MB. What fp holds beyond gfx, media, malloc and the committed heap is mostly Metaspace, the code cache and
// thread stacks.
#import <Foundation/Foundation.h>

// Starts this session's trail. Call once, on the thread that will call RMMemoryTrailSample.
void RMMemoryTrailStart(void);

// Writes a line if a minute has passed since the last one. The heap figures are negative until the VM can answer.
void RMMemoryTrailSample(long heapUsedMB, long heapCommittedMB);

// The kept trails, oldest first, each opening with the line that says when it started.
NSString *RMMemoryTrailReport(void);
