/* mpx_video: flat C ABI over FFmpeg (libavformat, libavcodec, libswscale)
 * and libvpx. Hand-written; the only API of this library. No FFmpeg type
 * crosses it.
 *
 * Threading: a MpxVideo handle is used by one thread at a time. Handles are
 * independent, so different handles may run on different threads in
 * parallel. There is no global state besides FFmpeg's log level.
 *
 * Lifetime: a handle is freed exactly once; a second free is undefined. The
 * bytes passed to mpx_video_open are copied; the caller keeps its buffer.
 *
 * Sources: a handle reads its file from memory (mpx_video_open), from a path
 * (mpx_video_open_file) or through a ranged reader (mpx_video_open_reader).
 * The last two read the bytes as the demuxer asks for them, at offsets: no
 * open loads a whole file into memory. A ranged reader blocks the calling
 * thread for bytes that have not arrived yet.
 *
 * Output: frames are premultiplied BGRA (byte order B, G, R, A), scaled to
 * the target size given at open (stretched, not letterboxed).
 *
 * Hostile input: every size, packet and frame count is capped (see the
 * MPX_VIDEO_MAX_* constants), every FFmpeg return is checked, and the
 * container cannot make FFmpeg open any file or URL.
 */
#ifndef MPX_VIDEO_H
#define MPX_VIDEO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The library is built with hidden visibility; only this ABI is exported. */
#define MPX_VIDEO_API __attribute__((visibility("default")))

/* Status codes. 0 is success, END_OF_STREAM is the one positive non-failure,
 * every failure is negative, and a code means one thing across calls. */
enum {
  MPX_VIDEO_STALLED = 2,           /* open, next: a ranged source has not brought the bytes needed yet; nothing waited, try again when more landed */
  MPX_VIDEO_END_OF_STREAM = 1,     /* next: no more frames until a rewind */
  MPX_VIDEO_OK = 0,
  MPX_VIDEO_INVALID_ARGUMENT = -1, /* a null pointer */
  MPX_VIDEO_TOO_LARGE = -2,        /* mpx_video_open: len over MPX_VIDEO_MAX_INPUT_BYTES, checked before the bytes are looked at */
  MPX_VIDEO_MALFORMED = -3,        /* open: not a container this build reads, or no readable stream info */
  MPX_VIDEO_LIMIT_EXCEEDED = -4,   /* open: source dimensions over the cap; next: packet or frame budget spent */
  MPX_VIDEO_UNSUPPORTED = -5,      /* open: no video stream, or its codec is not built in */
  MPX_VIDEO_INTERNAL = -6,         /* allocation or FFmpeg internal failure: not the file's fault */
  MPX_VIDEO_BAD_SIZE = -7,         /* open: target edge zero or over the cap; next: stride under the row width */
  MPX_VIDEO_DECODE_FAILED = -8,    /* next: the stream is damaged beyond the tolerated bad packets; rewind: cannot seek */
  MPX_VIDEO_SOURCE_FAILED = -9     /* open, next: the source could not be read (no such file, a reader that is not published, a fetch that failed, a resource withdrawn) */
};

/* Caps. Changing one is an ABI-visible behaviour change. */
enum {
  MPX_VIDEO_MAX_INPUT_BYTES = 10 * 1024 * 1024, /* 10 MiB gate on the copy mpx_video_open holds; a file or reader is read in place and has none */
  MPX_VIDEO_MAX_SOURCE_EDGE = 3840,             /* per-side cap */
  MPX_VIDEO_MAX_SOURCE_PIXELS = 3840 * 2160,
  MPX_VIDEO_MAX_TARGET_EDGE = 2048,
  MPX_VIDEO_MAX_PACKETS_PER_PASS = 20000,       /* packets read between rewinds */
  MPX_VIDEO_MAX_FRAMES_PER_PASS = 10000,        /* frames decoded between rewinds */
  MPX_VIDEO_MAX_SKIPPED_PACKETS = 10            /* consecutive undecodable packets tolerated */
};

enum { MPX_VIDEO_ABI_VERSION = 3 };

typedef struct MpxVideo MpxVideo; /* opaque */

typedef struct {
  uint32_t width;       /* the size shown: the source's, turned by quarters as the */
  uint32_t height;      /* container's display matrix asks; frames come turned too */
  int64_t duration_ms;  /* -1 when the container declares none */
  float frame_rate;     /* 0 when unknown */
  uint32_t has_alpha;   /* 1 when the stream declares alpha (WebM alpha_mode, or an alpha pixel format; never for GIF) */
} MpxVideoInfo;

/* The load probe: returns MPX_VIDEO_ABI_VERSION. */
MPX_VIDEO_API uint32_t mpx_video_abi_version(void);

/* Opens an in-memory file for frames of target_w x target_h. On success
 * returns 0, fills *out_handle; on failure returns a negative status and
 * sets *out_handle to NULL. VP9 is always decoded by libvpx-vp9 (the native
 * decoder drops alpha, FFmpeg Trac #8344). */
MPX_VIDEO_API int32_t mpx_video_open(const uint8_t *data, size_t len, uint32_t target_w,
                        uint32_t target_h, MpxVideo **out_handle);

/* Opens the file at path for frames of target_w x target_h, reading it in
 * place. Statuses as mpx_video_open, plus MPX_VIDEO_SOURCE_FAILED when the
 * file cannot be opened or read. No byte cap applies: nothing is copied, so
 * a file is bounded by the dimension caps and the per-pass budgets. */
MPX_VIDEO_API int32_t mpx_video_open_file(const char *path, uint32_t target_w,
                        uint32_t target_h, MpxVideo **out_handle);

/* The oldest version of the ranged reader table mpx_video_open_reader
 * reads (the one with reader_available). */
enum { MPX_VIDEO_READER_ABI_VERSION = 3 };

/* Bytes past the read position a ranged source must hold before next
 * demuxes another packet, when the open passes no lookahead of its own
 * (lookahead <= 0): below it, next answers MPX_VIDEO_STALLED and asks for
 * them, instead of starting a packet it cannot finish. */
enum { MPX_VIDEO_READER_LOOKAHEAD = 512 * 1024 };

/* Opens the ranged resource `key` through the reader table at reader_api,
 * for frames of target_w x target_h. The table is the bytes cache's native
 * reader (hbc_api of http_bytes_cache.h, whose version field must be
 * MPX_VIDEO_READER_ABI_VERSION; another version is
 * MPX_VIDEO_INVALID_ARGUMENT). The handle opens a reader of its own, reads
 * through it at offsets, and closes it when freed.
 *
 * Nothing waits for bytes that have not landed: the reader is asked what is
 * there (reader_available) before each read, and a call that needs missing
 * bytes asks for them and answers MPX_VIDEO_STALLED at once. An open that
 * stalls holds nothing: open again when more landed. A next that stalls
 * keeps the handle: it reads no further packet until `lookahead` bytes
 * past its position are there (MPX_VIDEO_READER_LOOKAHEAD for <= 0), and
 * when a packet was cut short it goes back to the frame after the last one
 * it returned, so the frames come out as they would have, none skipped and
 * none twice. The open needs the resource's length (it asks for the first
 * bytes and returns STALLED until a response named it). No byte cap
 * applies, as for mpx_video_open_file. A resource withdrawn by its host
 * fails with MPX_VIDEO_SOURCE_FAILED. */
MPX_VIDEO_API int32_t mpx_video_open_reader(const void *reader_api, const char *key,
                        int64_t lookahead, uint32_t target_w, uint32_t target_h,
                        MpxVideo **out_handle);

/* Describes the open video. */
MPX_VIDEO_API int32_t mpx_video_info(const MpxVideo *handle, MpxVideoInfo *out_info);

/* Decodes the next frame into dst (top-left pixel of a target_w x target_h
 * slot, rows stride bytes apart, stride >= target_w * 4) and stores its
 * presentation time in *out_pts_ms. Returns 0, MPX_VIDEO_END_OF_STREAM
 * (dst untouched) or a failure. */
MPX_VIDEO_API int32_t mpx_video_next(MpxVideo *handle, uint8_t *dst, size_t stride,
                        int64_t *out_pts_ms);

/* Seeks to the start and flushes the decoder, for looping. Resets the
 * per-pass budgets. */
MPX_VIDEO_API int32_t mpx_video_rewind(MpxVideo *handle);

/* Seeks to position_ms (from the stream's start): back to the keyframe at
 * or before it, then the next mpx_video_next decodes forward and returns
 * the first frame at or after it, the frames before decoded and dropped. A
 * position past the last frame returns the last frame, then the end. 0 is a
 * rewind. Resets the per-pass budgets. Returns 0, MPX_VIDEO_INVALID_ARGUMENT
 * (a null handle or a negative position) or MPX_VIDEO_DECODE_FAILED (cannot
 * seek at all). */
MPX_VIDEO_API int32_t mpx_video_seek(MpxVideo *handle, int64_t position_ms);

/* Releases a handle. NULL is accepted. */
MPX_VIDEO_API void mpx_video_free(MpxVideo *handle);

#ifdef __cplusplus
}
#endif

#endif
