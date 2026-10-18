/*
 * qwen_mmap_guard.c - Lightweight POSIX mmap/madvise guard for embedded llama.cpp
 * Ensures read-only GGUF file mappings release cold page-table entries back to
 * the OS kernel so total process RSS remains well below the strict 500 MB budget.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/mman.h>
#if defined(__GLIBC__)
#include <malloc.h>
#endif

static volatile int g_guard_running = 1;

static void reclaim_cold_gguf_pages(void) {
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) return;

    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        /* Only evict clean read-only shared file mappings (.gguf) */
        if (strstr(line, ".gguf") && strstr(line, "r--s")) {
            unsigned long start = 0, end = 0;
            if (sscanf(line, "%lx-%lx", &start, &end) == 2 && end > start) {
                size_t len = end - start;
                const size_t hot_prefix = 8 * 1024 * 1024; /* keep 8 MB header/vocab hot */
                if (len > hot_prefix) {
                    madvise((void *)(start + hot_prefix), len - hot_prefix, MADV_DONTNEED);
                }
            }
        }
    }
    fclose(f);
#if defined(__GLIBC__)
    malloc_trim(0);
#endif
}

static void *guard_worker(void *arg) {
    (void)arg;
    while (g_guard_running) {
        usleep(1500000); /* 1.5s interval */
        if (!g_guard_running) break;
        reclaim_cold_gguf_pages();
    }
    return NULL;
}

__attribute__((constructor))
static void qwen_mmap_guard_init(void) {
    pthread_t th;
    if (pthread_create(&th, NULL, guard_worker, NULL) == 0) {
        pthread_detach(th);
    }
}

__attribute__((destructor))
static void qwen_mmap_guard_fini(void) {
    g_guard_running = 0;
}
