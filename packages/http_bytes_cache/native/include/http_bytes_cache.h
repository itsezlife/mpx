/*
 * Native reader of http_bytes_cache's ranged resources.
 *
 * A ranged resource is one sparse file plus the byte ranges present in it.
 * The Dart side of the cache fetches bytes, writes them into the file and
 * tells this library which ranges landed. Native players open a reader by
 * cache key and read the file directly: a read of present bytes returns at
 * once; a read of missing bytes asks Dart to fetch them (at the reader's
 * priority) and blocks until they land, the read is cancelled, the fetch
 * fails or the resource is unpublished.
 *
 * Reader calls may block and must run on a thread of the player, never on a
 * thread that runs a Dart isolate. Host calls (hbc_publish and the other
 * hbc_* calls without "reader") are the Dart side's; they never block on IO.
 *
 * Players reach the functions through hbc_get_api(): the Dart side hands the
 * table's address to the player's native code, so nothing has to link this
 * library by name or path.
 */
#ifndef HTTP_BYTES_CACHE_H_
#define HTTP_BYTES_CACHE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define HBC_EXPORT __declspec(dllexport)
#else
#define HBC_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

/* Version of this interface; hbc_api.version carries it. */
#define HBC_ABI_VERSION 2

/* hbc_reader_read results below zero. Zero means end of the resource. */
#define HBC_ERR_CANCELLED (-1) /* hbc_reader_cancel woke the read */
#define HBC_ERR_FAILED (-2)    /* the fetch of the missing bytes failed */
#define HBC_ERR_CLOSED (-3)    /* the resource was unpublished */
#define HBC_ERR_IO (-4)        /* the file could not be read */
#define HBC_ERR_BUSY (-5)      /* hbc_attach: another host is attached */

/* Priorities, as the Dart side's RequestPriority. */
#define HBC_PRIORITY_BACKGROUND 0
#define HBC_PRIORITY_PRELOAD 1
#define HBC_PRIORITY_VISIBLE 2

typedef struct hbc_reader hbc_reader;

/* Asks the Dart side to fetch [offset, offset + length) of a resource. Must
 * not block (the Dart side registers an asynchronous callback). */
typedef void (*hbc_fetch_fn)(int64_t resource_id, int64_t offset,
                             int64_t length, int32_t priority);

/* --- Host side (the cache's Dart code) --------------------------------- */

HBC_EXPORT int32_t hbc_abi_version(void);

/* Attaches the one host of this process, which [fetch] reaches. Returns its
 * owner token (> 0), or HBC_ERR_BUSY while another host is attached (from
 * any isolate) or when [fetch] is NULL. */
HBC_EXPORT int64_t hbc_attach(hbc_fetch_fn fetch);

/* Detaches the host [owner]: drops the fetch callback and withdraws every
 * published resource (blocked and later reads return HBC_ERR_CLOSED). A
 * token that is not the attached one is ignored. */
HBC_EXPORT void hbc_detach(int64_t owner);

/* hbc_detach for a Dart NativeFinalizer, whose token is [owner]: when the
 * host's isolate group ends without detaching (a hot restart), the
 * finalizer detaches it, so the next host attaches to a clean library and
 * nothing calls the dead host's callback. */
HBC_EXPORT void hbc_detach_finalizer(void *owner);

/* Publishes the resource [key] whose sparse file is [path]. [total_length]
 * is -1 when unknown. Returns its id (> 0), or 0 when out of memory.
 * Publishing a published key returns its id, updates path and length, and
 * counts one more publication: each publication is withdrawn by its own
 * hbc_unpublish. */
HBC_EXPORT int64_t hbc_publish(const char *key, const char *path,
                               int64_t total_length);

/* The representation's length became known. */
HBC_EXPORT void hbc_set_length(int64_t id, int64_t total_length);

/* Bytes [start, end) are in the file: the "range landed" signal. Wakes
 * every reader blocked on them. */
HBC_EXPORT void hbc_range_landed(int64_t id, int64_t start, int64_t end);

/* Every span was dropped (another representation); readers forget them. */
HBC_EXPORT void hbc_ranges_reset(int64_t id);

/* The fetch of [offset, offset + length) failed: readers blocked inside it
 * return HBC_ERR_FAILED. */
HBC_EXPORT void hbc_fetch_failed(int64_t id, int64_t offset, int64_t length);

/* Withdraws one publication of the resource. At the last one, blocked and
 * later reads return HBC_ERR_CLOSED. */
HBC_EXPORT void hbc_unpublish(int64_t id);

/* --- Reader side (players, on their own threads) ------------------------ */

/* Opens a reader on the published resource [key], or NULL when it is not
 * published or its file cannot be opened. */
HBC_EXPORT hbc_reader *hbc_reader_open(const char *key);

/* The resource's length, or -1 when unknown. With [wait] non-zero, asks for
 * the first bytes when needed and blocks until the length is known (or
 * returns a negative HBC_ERR_* code). */
HBC_EXPORT int64_t hbc_reader_length(hbc_reader *reader, int32_t wait);

/* Reads up to [length] bytes at [offset] into [buffer]. Returns the count
 * read (at least 1), 0 at the end, or a negative HBC_ERR_* code. Blocks
 * while the byte at [offset] is missing. A read that races a reset (the
 * file no longer holds bytes counted present, or changed under the read)
 * waits for the next landing or reset and reads again; HBC_ERR_IO only when
 * the file read fails, or nothing follows the short read for seconds. The
 * store empties a payload by putting a new file in its place: the reader
 * keeps the file it opened until a reset, or a short read, shows that the
 * path holds another file, and then reopens it. */
HBC_EXPORT int64_t hbc_reader_read(hbc_reader *reader, int64_t offset,
                                   uint8_t *buffer, int64_t length);

/* The priority this reader's fetches ask at (default visible). */
HBC_EXPORT void hbc_reader_set_priority(hbc_reader *reader, int32_t priority);

/* Wakes the reads blocked on this reader now with HBC_ERR_CANCELLED. Later
 * reads block again as usual. Any thread. */
HBC_EXPORT void hbc_reader_cancel(hbc_reader *reader);

/* Closes the reader. No call on it may be running or follow. */
HBC_EXPORT void hbc_reader_close(hbc_reader *reader);

/* The reader functions as one table, for players handed its address. */
typedef struct hbc_api {
  int32_t version; /* HBC_ABI_VERSION */
  hbc_reader *(*reader_open)(const char *key);
  int64_t (*reader_length)(hbc_reader *reader, int32_t wait);
  int64_t (*reader_read)(hbc_reader *reader, int64_t offset, uint8_t *buffer,
                         int64_t length);
  void (*reader_set_priority)(hbc_reader *reader, int32_t priority);
  void (*reader_cancel)(hbc_reader *reader);
  void (*reader_close)(hbc_reader *reader);
} hbc_api;

HBC_EXPORT const hbc_api *hbc_get_api(void);

#ifdef __cplusplus
}
#endif

#endif /* HTTP_BYTES_CACHE_H_ */
