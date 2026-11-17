/* mpx_video: see include/mpx_video.h for the contract. */
#include "mpx_video.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- Ranged reader table ----------------------------------------------- */

/* Mirror of the bytes cache's reader table (hbc_api in http_bytes_cache.h,
 * version MPX_VIDEO_READER_ABI_VERSION). Mirrored instead of included: the
 * wrapper is built without the cache's sources, and the version check keeps
 * the mirror honest. */
typedef struct mpx_video_reader mpx_video_reader;
typedef struct {
  int32_t version;
  mpx_video_reader *(*reader_open)(const char *key);
  int64_t (*reader_length)(mpx_video_reader *reader, int32_t wait);
  int64_t (*reader_read)(mpx_video_reader *reader, int64_t offset, uint8_t *buffer,
                         int64_t length);
  void (*reader_set_priority)(mpx_video_reader *reader, int32_t priority);
  void (*reader_cancel)(mpx_video_reader *reader);
  void (*reader_close)(mpx_video_reader *reader);
  int64_t (*reader_available)(mpx_video_reader *reader, int64_t offset,
                              int64_t length);
} ReaderApi;

/* --- Handle ----------------------------------------------------------- */

typedef enum {
  STATE_RUNNING,
  STATE_DRAINING, /* the flush packet is sent; frames still come out */
  STATE_DONE,     /* end of stream reached */
  STATE_SPENT     /* a failure; only a rewind revives the handle */
} State;

typedef enum {
  SOURCE_MEMORY, /* `data`, a copy of the caller's bytes */
  SOURCE_FILE,   /* `file`, read in place */
  SOURCE_READER  /* `reader` through `api`, blocking for missing bytes */
} SourceKind;

struct MpxVideo {
  /* The file: AVIO reads it through the cursor `pos`, whatever holds it. */
  SourceKind source;
  uint8_t *data;
  FILE *file;
  const ReaderApi *api;
  mpx_video_reader *reader;
  int64_t size;
  int64_t pos;
  /* A read of the source failed (not the end): the open or the decode that
   * ran into it reports MPX_VIDEO_SOURCE_FAILED, not a damaged file. */
  int source_failed;
  /* A read of a ranged source found its bytes missing: the call answers
   * MPX_VIDEO_STALLED. */
  int stalled;
  /* A packet was cut short by a stall: the next next goes back to the
   * frame after `resume_ms` first (-1 for the start). */
  int resume;
  int64_t resume_ms;
  /* Bytes past the position next wants present before a packet. */
  int64_t lookahead;

  AVIOContext *avio;
  AVFormatContext *fmt;
  AVCodecContext *dec;
  AVPacket *pkt;
  AVFrame *frame;
  struct SwsContext *sws;
  int stream;

  uint32_t target_w, target_h;
  MpxVideoInfo info;

  State state;
  int64_t packets; /* read since the last rewind */
  int64_t frames;  /* decoded since the last rewind */
  int skipped;     /* consecutive undecodable packets */
  int64_t last_pts_ms; /* -1 before the first frame of a pass */

  /* After a seek: frames before this time are decoded and dropped; -1 when
   * no seek is pending. The last one dropped is kept in `held`, in case the
   * stream ends before the time. */
  int64_t seek_ms;
  AVFrame *held;
};

/* --- AVIO over the source --------------------------------------------- */

static int read_source(void *opaque, uint8_t *buf, int buf_size) {
  MpxVideo *h = opaque;
  int64_t left = h->size - h->pos;
  if (left <= 0) return AVERROR_EOF;
  int64_t want = buf_size < left ? buf_size : left;
  int64_t n = 0;
  switch (h->source) {
    case SOURCE_MEMORY:
      memcpy(buf, h->data + h->pos, (size_t)want);
      n = want;
      break;
    case SOURCE_FILE:
      if (fseek(h->file, (long)h->pos, SEEK_SET) != 0) goto failed;
      n = (int64_t)fread(buf, 1, (size_t)want, h->file);
      if (n == 0) {
        if (ferror(h->file)) goto failed;
        return AVERROR_EOF; /* shorter than it was at open */
      }
      break;
    case SOURCE_READER: {
      /* Only what is there: a missing byte is asked for, never waited on. */
      int64_t end = h->api->reader_available(h->reader, h->pos, want);
      if (end < 0) goto failed;
      if (end <= h->pos) {
        h->stalled = 1;
        return AVERROR(EAGAIN);
      }
      if (end - h->pos < want) want = end - h->pos;
      n = h->api->reader_read(h->reader, h->pos, buf, want);
      if (n == 0) return AVERROR_EOF;
      if (n < 0) goto failed;
      break;
    }
  }
  h->pos += n;
  return (int)n;

failed:
  h->source_failed = 1;
  return AVERROR(EIO);
}

static int64_t seek_source(void *opaque, int64_t offset, int whence) {
  MpxVideo *h = opaque;
  if (whence & AVSEEK_SIZE) return h->size;
  int64_t base;
  switch (whence & ~AVSEEK_FORCE) {
    case SEEK_SET: base = 0; break;
    case SEEK_CUR: base = h->pos; break;
    case SEEK_END: base = h->size; break;
    default: return AVERROR(EINVAL);
  }
  int64_t at = base + offset;
  if (at < 0 || at > h->size) return AVERROR(EINVAL);
  h->pos = at;
  return at;
}

/* --- Lifetime ---------------------------------------------------------- */

void mpx_video_free(MpxVideo *h) {
  if (!h) return;
  sws_freeContext(h->sws);
  av_frame_free(&h->frame);
  av_frame_free(&h->held);
  av_packet_free(&h->pkt);
  avcodec_free_context(&h->dec);
  /* Closes the input (with a custom pb it does not free the pb itself). */
  avformat_close_input(&h->fmt);
  if (h->avio) {
    av_freep(&h->avio->buffer);
    avio_context_free(&h->avio);
  }
  free(h->data);
  if (h->file) fclose(h->file);
  if (h->reader) h->api->reader_close(h->reader);
  free(h);
}

static void quiet_ffmpeg_once(void) {
  static atomic_int done;
  if (atomic_exchange(&done, 1) == 0) av_log_set_level(AV_LOG_QUIET);
}

static int has_alpha_format(int format) {
  const AVPixFmtDescriptor *d = format >= 0 ? av_pix_fmt_desc_get(format) : NULL;
  return d && (d->flags & AV_PIX_FMT_FLAG_ALPHA);
}

static int32_t open_decoder(MpxVideo *h) {
  AVDictionary *opts = NULL;
  /* The container must not make FFmpeg open anything but our memory. */
  av_dict_set(&opts, "protocol_whitelist", "", 0);

  h->fmt = avformat_alloc_context();
  if (!h->fmt) return MPX_VIDEO_INTERNAL;
  h->fmt->pb = h->avio;
  h->fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
  int r = avformat_open_input(&h->fmt, NULL, NULL, &opts);
  av_dict_free(&opts);
  /* h->fmt is freed and NULL on failure. */
  if (r < 0)
    return h->stalled         ? MPX_VIDEO_STALLED
           : h->source_failed ? MPX_VIDEO_SOURCE_FAILED
                              : MPX_VIDEO_MALFORMED;
  r = avformat_find_stream_info(h->fmt, NULL);
  /* Probing reads packets: one cut short means the bytes are on their way,
   * not a damaged file. */
  if (h->stalled) return MPX_VIDEO_STALLED;
  if (r < 0) return h->source_failed ? MPX_VIDEO_SOURCE_FAILED : MPX_VIDEO_MALFORMED;

  h->stream = av_find_best_stream(h->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (h->stream < 0) return MPX_VIDEO_UNSUPPORTED;
  AVStream *st = h->fmt->streams[h->stream];
  AVCodecParameters *par = st->codecpar;

  if (par->width <= 0 || par->height <= 0) return MPX_VIDEO_MALFORMED;
  if (par->width > MPX_VIDEO_MAX_SOURCE_EDGE ||
      par->height > MPX_VIDEO_MAX_SOURCE_EDGE ||
      (int64_t)par->width * par->height > MPX_VIDEO_MAX_SOURCE_PIXELS)
    return MPX_VIDEO_LIMIT_EXCEEDED;

  const AVCodec *codec = NULL;
  if (par->codec_id == AV_CODEC_ID_VP9) {
    /* Forced: FFmpeg's own vp9 decoder drops the alpha plane (Trac #8344). */
    codec = avcodec_find_decoder_by_name("libvpx-vp9");
  } else {
    codec = avcodec_find_decoder(par->codec_id);
  }
  if (!codec) return MPX_VIDEO_UNSUPPORTED;

  h->dec = avcodec_alloc_context3(codec);
  if (!h->dec) return MPX_VIDEO_INTERNAL;
  if (avcodec_parameters_to_context(h->dec, par) < 0) return MPX_VIDEO_INTERNAL;
  /* The decoder refuses frames over the area cap, with slack for padding. */
  h->dec->max_pixels = MPX_VIDEO_MAX_SOURCE_PIXELS + MPX_VIDEO_MAX_SOURCE_PIXELS / 32 + 64 * 1024;
  if (avcodec_open2(h->dec, codec, NULL) < 0) return MPX_VIDEO_UNSUPPORTED;

  h->pkt = av_packet_alloc();
  h->frame = av_frame_alloc();
  h->held = av_frame_alloc();
  if (!h->pkt || !h->frame || !h->held) return MPX_VIDEO_INTERNAL;

  AVRational rate = av_guess_frame_rate(h->fmt, st, NULL);
  const AVDictionaryEntry *alpha_mode = av_dict_get(st->metadata, "alpha_mode", NULL, 0);
  h->info.width = (uint32_t)par->width;
  h->info.height = (uint32_t)par->height;
  h->info.duration_ms = h->fmt->duration != AV_NOPTS_VALUE ? h->fmt->duration / 1000 : -1;
  h->info.frame_rate = rate.den > 0 && rate.num > 0 ? (float)av_q2d(rate) : 0.0f;
  /* GIF always decodes to BGRA whatever the file holds, so its pixel format
   * says nothing; every other codec's declared format does. */
  h->info.has_alpha = (alpha_mode && strcmp(alpha_mode->value, "1") == 0) ||
                      (par->codec_id != AV_CODEC_ID_GIF && has_alpha_format(par->format));
  return MPX_VIDEO_OK;
}

static int bad_target(uint32_t target_w, uint32_t target_h) {
  return target_w == 0 || target_h == 0 || target_w > MPX_VIDEO_MAX_TARGET_EDGE ||
         target_h > MPX_VIDEO_MAX_TARGET_EDGE;
}

static MpxVideo *new_handle(SourceKind source, uint32_t target_w, uint32_t target_h) {
  MpxVideo *h = calloc(1, sizeof *h);
  if (!h) return NULL;
  h->source = source;
  h->target_w = target_w;
  h->target_h = target_h;
  h->last_pts_ms = -1;
  h->seek_ms = -1;
  return h;
}

/* Builds the AVIO and the decoder over the source. The byte cap is the
 * in-memory open's own (it bounds the copy held): a file or a reader is
 * read in place, a buffer at a time, whatever its size. Frees the handle on
 * failure. */
static int32_t finish_open(MpxVideo *h, MpxVideo **out_handle) {
  int32_t status = MPX_VIDEO_INTERNAL;
  if (h->size == 0) {
    status = MPX_VIDEO_MALFORMED;
    goto fail;
  }
  quiet_ffmpeg_once();

  const int io_size = 32 * 1024;
  uint8_t *io_buffer = av_malloc(io_size);
  if (!io_buffer) goto fail;
  h->avio = avio_alloc_context(io_buffer, io_size, 0, h, read_source, NULL, seek_source);
  if (!h->avio) {
    av_free(io_buffer);
    goto fail;
  }

  status = open_decoder(h);
  if (status != MPX_VIDEO_OK) goto fail;
  *out_handle = h;
  return MPX_VIDEO_OK;

fail:
  mpx_video_free(h);
  return status;
}

int32_t mpx_video_open(const uint8_t *data, size_t len, uint32_t target_w,
                        uint32_t target_h, MpxVideo **out_handle) {
  if (!out_handle) return MPX_VIDEO_INVALID_ARGUMENT;
  *out_handle = NULL;
  if (!data) return MPX_VIDEO_INVALID_ARGUMENT;
  /* Before the bytes are looked at. */
  if (len > MPX_VIDEO_MAX_INPUT_BYTES) return MPX_VIDEO_TOO_LARGE;
  if (len == 0) return MPX_VIDEO_MALFORMED;
  if (bad_target(target_w, target_h)) return MPX_VIDEO_BAD_SIZE;

  MpxVideo *h = new_handle(SOURCE_MEMORY, target_w, target_h);
  if (!h) return MPX_VIDEO_INTERNAL;
  h->data = malloc(len);
  if (!h->data) {
    mpx_video_free(h);
    return MPX_VIDEO_INTERNAL;
  }
  memcpy(h->data, data, len);
  h->size = (int64_t)len;
  return finish_open(h, out_handle);
}

int32_t mpx_video_open_file(const char *path, uint32_t target_w, uint32_t target_h,
                            MpxVideo **out_handle) {
  if (!out_handle) return MPX_VIDEO_INVALID_ARGUMENT;
  *out_handle = NULL;
  if (!path) return MPX_VIDEO_INVALID_ARGUMENT;
  if (bad_target(target_w, target_h)) return MPX_VIDEO_BAD_SIZE;

  MpxVideo *h = new_handle(SOURCE_FILE, target_w, target_h);
  if (!h) return MPX_VIDEO_INTERNAL;
  h->file = fopen(path, "rb");
  long size = -1;
  if (h->file && fseek(h->file, 0, SEEK_END) == 0) size = ftell(h->file);
  if (size < 0) {
    mpx_video_free(h);
    return MPX_VIDEO_SOURCE_FAILED;
  }
  h->size = size;
  return finish_open(h, out_handle);
}

int32_t mpx_video_open_reader(const void *reader_api, const char *key,
                              int64_t lookahead, uint32_t target_w,
                              uint32_t target_h, MpxVideo **out_handle) {
  if (!out_handle) return MPX_VIDEO_INVALID_ARGUMENT;
  *out_handle = NULL;
  const ReaderApi *api = reader_api;
  if (!api || !key || api->version != MPX_VIDEO_READER_ABI_VERSION)
    return MPX_VIDEO_INVALID_ARGUMENT;
  if (bad_target(target_w, target_h)) return MPX_VIDEO_BAD_SIZE;

  MpxVideo *h = new_handle(SOURCE_READER, target_w, target_h);
  if (!h) return MPX_VIDEO_INTERNAL;
  h->api = api;
  h->lookahead = lookahead > 0 ? lookahead : MPX_VIDEO_READER_LOOKAHEAD;
  h->reader = api->reader_open(key);
  int64_t size = -1;
  if (h->reader) {
    size = api->reader_length(h->reader, 0);
    /* Unknown until a response names it: ask for the first bytes, which
     * tells it, and come back. */
    if (size == -1) {
      int64_t asked = api->reader_available(h->reader, 0, MPX_VIDEO_READER_LOOKAHEAD);
      mpx_video_free(h);
      return asked < 0 ? MPX_VIDEO_SOURCE_FAILED : MPX_VIDEO_STALLED;
    }
  }
  if (size < 0) {
    mpx_video_free(h);
    return MPX_VIDEO_SOURCE_FAILED;
  }
  h->size = size;
  return finish_open(h, out_handle);
}

int32_t mpx_video_info(const MpxVideo *h, MpxVideoInfo *out_info) {
  if (!h || !out_info) return MPX_VIDEO_INVALID_ARGUMENT;
  *out_info = h->info;
  return MPX_VIDEO_OK;
}

/* --- Decoding ---------------------------------------------------------- */

/* c = c * a / 255, rounded, on straight BGRA rows. */
static void premultiply(uint8_t *dst, size_t stride, uint32_t w, uint32_t h) {
  for (uint32_t y = 0; y < h; y++) {
    uint8_t *p = dst + y * stride;
    for (uint32_t x = 0; x < w; x++, p += 4) {
      uint32_t a = p[3];
      if (a == 255) continue;
      p[0] = (uint8_t)((p[0] * a + 127) / 255);
      p[1] = (uint8_t)((p[1] * a + 127) / 255);
      p[2] = (uint8_t)((p[2] * a + 127) / 255);
    }
  }
}

/* Scales the decoded frame into dst as BGRA. */
static int32_t convert(MpxVideo *h, uint8_t *dst, size_t stride) {
  const AVFrame *f = h->frame;
  if (f->width <= 0 || f->height <= 0 || f->width > MPX_VIDEO_MAX_SOURCE_EDGE ||
      f->height > MPX_VIDEO_MAX_SOURCE_EDGE ||
      (int64_t)f->width * f->height > MPX_VIDEO_MAX_SOURCE_PIXELS)
    return MPX_VIDEO_LIMIT_EXCEEDED;
  h->sws = sws_getCachedContext(h->sws, f->width, f->height, f->format, (int)h->target_w,
                                (int)h->target_h, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
  if (!h->sws) return MPX_VIDEO_DECODE_FAILED; /* a format swscale cannot read */
  uint8_t *planes[4] = {dst, NULL, NULL, NULL};
  int strides[4] = {(int)stride, 0, 0, 0};
  if (sws_scale(h->sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, planes,
                strides) != (int)h->target_h)
    return MPX_VIDEO_DECODE_FAILED;
  if (has_alpha_format(f->format)) premultiply(dst, stride, h->target_w, h->target_h);
  return MPX_VIDEO_OK;
}

static int64_t frame_pts_ms(MpxVideo *h) {
  int64_t ts = h->frame->best_effort_timestamp;
  AVStream *st = h->fmt->streams[h->stream];
  if (ts == AV_NOPTS_VALUE) {
    /* Without a timestamp, one frame period after the last one. */
    int64_t period = h->info.frame_rate > 0 ? (int64_t)(1000.0f / h->info.frame_rate) : 40;
    return h->last_pts_ms < 0 ? 0 : h->last_pts_ms + period;
  }
  if (st->start_time != AV_NOPTS_VALUE) ts -= st->start_time;
  int64_t ms = av_rescale_q(ts, st->time_base, (AVRational){1, 1000});
  return ms < 0 ? 0 : ms;
}

static int32_t spend(MpxVideo *h, int32_t status) {
  h->state = STATE_SPENT;
  return status;
}

/* The stream ended. A seek past the last frame shows that frame (kept in
 * `held`) once, then the end; otherwise the end at once. */
static int32_t end_of_stream(MpxVideo *h, uint8_t *dst, size_t stride, int64_t *out_pts_ms) {
  h->state = STATE_DONE;
  if (h->seek_ms < 0 || !h->held->buf[0]) {
    h->seek_ms = -1;
    return MPX_VIDEO_END_OF_STREAM;
  }
  h->seek_ms = -1;
  av_frame_unref(h->frame);
  av_frame_move_ref(h->frame, h->held);
  int32_t status = convert(h, dst, stride);
  if (status == MPX_VIDEO_OK) {
    *out_pts_ms = h->last_pts_ms = frame_pts_ms(h);
  }
  av_frame_unref(h->frame);
  return status == MPX_VIDEO_OK ? MPX_VIDEO_OK : spend(h, status);
}

/* A stall cut a packet short: the demuxer's state is past bytes it never
 * got. The AVIO's error is cleared and the stream sought back to the frame
 * after the last one returned, whose predecessors the seek drops. */
static int32_t resume_after_stall(MpxVideo *h) {
  int64_t last = h->resume_ms;
  int32_t status = last < 0 ? mpx_video_rewind(h) : mpx_video_seek(h, last + 1);
  /* The seek itself needed bytes that are not there: still to do. */
  if (status == MPX_VIDEO_OK && h->resume) return MPX_VIDEO_STALLED;
  return status;
}

/* Marks a stall that cut a packet short. */
static int32_t stall_mid_packet(MpxVideo *h) {
  h->resume = 1;
  h->resume_ms = h->last_pts_ms;
  return MPX_VIDEO_STALLED;
}

int32_t mpx_video_next(MpxVideo *h, uint8_t *dst, size_t stride, int64_t *out_pts_ms) {
  if (!h || !dst || !out_pts_ms) return MPX_VIDEO_INVALID_ARGUMENT;
  if (stride < (size_t)h->target_w * 4) return MPX_VIDEO_BAD_SIZE;
  if (h->state == STATE_DONE) return MPX_VIDEO_END_OF_STREAM;
  if (h->state == STATE_SPENT) return MPX_VIDEO_DECODE_FAILED;
  if (h->resume) {
    int32_t status = resume_after_stall(h);
    if (status != MPX_VIDEO_OK) return status == MPX_VIDEO_STALLED ? status : spend(h, status);
  }

  for (;;) {
    int r = avcodec_receive_frame(h->dec, h->frame);
    if (r == 0) {
      if (h->frames >= MPX_VIDEO_MAX_FRAMES_PER_PASS) {
        av_frame_unref(h->frame);
        return spend(h, MPX_VIDEO_LIMIT_EXCEEDED);
      }
      h->frames++;
      if (h->seek_ms >= 0) {
        int64_t pts = frame_pts_ms(h);
        if (pts < h->seek_ms) {
          /* Before the time sought: dropped, but kept in case the stream
           * ends first. */
          h->last_pts_ms = pts;
          av_frame_unref(h->held);
          av_frame_move_ref(h->held, h->frame);
          continue;
        }
        h->seek_ms = -1;
        av_frame_unref(h->held);
      }
      int32_t status = convert(h, dst, stride);
      if (status == MPX_VIDEO_OK) {
        *out_pts_ms = h->last_pts_ms = frame_pts_ms(h);
        h->skipped = 0;
      }
      av_frame_unref(h->frame);
      return status == MPX_VIDEO_OK ? MPX_VIDEO_OK : spend(h, status);
    }
    if (r == AVERROR_EOF) return end_of_stream(h, dst, stride, out_pts_ms);
    if (r != AVERROR(EAGAIN)) return spend(h, MPX_VIDEO_DECODE_FAILED);
    /* EAGAIN after the flush packet cannot happen; do not wait for it. */
    if (h->state == STATE_DRAINING) return end_of_stream(h, dst, stride, out_pts_ms);

    /* The decoder wants a packet. */
    if (h->packets >= MPX_VIDEO_MAX_PACKETS_PER_PASS) return spend(h, MPX_VIDEO_LIMIT_EXCEEDED);
    if (h->source == SOURCE_READER) {
      /* No packet is started without room to finish it: the demuxer's
       * state stays where it is, and nothing needs undoing. */
      int64_t want = h->lookahead;
      int64_t need = h->pos + want < h->size ? h->pos + want : h->size;
      int64_t end = h->api->reader_available(h->reader, h->pos, want);
      if (end < 0) return spend(h, MPX_VIDEO_SOURCE_FAILED);
      if (end < need) return MPX_VIDEO_STALLED;
    }
    r = av_read_frame(h->fmt, h->pkt);
    if (h->stalled) {
      av_packet_unref(h->pkt);
      return stall_mid_packet(h);
    }
    if (r == AVERROR_EOF && !h->source_failed) {
      h->state = STATE_DRAINING;
      if (avcodec_send_packet(h->dec, NULL) < 0) return spend(h, MPX_VIDEO_DECODE_FAILED);
      continue;
    }
    if (r < 0 || h->source_failed)
      return spend(h, h->source_failed ? MPX_VIDEO_SOURCE_FAILED : MPX_VIDEO_DECODE_FAILED);
    h->packets++;
    if (h->pkt->stream_index != h->stream) {
      av_packet_unref(h->pkt);
      continue;
    }
    r = avcodec_send_packet(h->dec, h->pkt);
    av_packet_unref(h->pkt);
    if (r == AVERROR_INVALIDDATA && ++h->skipped <= MPX_VIDEO_MAX_SKIPPED_PACKETS) continue;
    if (r < 0 && r != AVERROR(EAGAIN)) return spend(h, MPX_VIDEO_DECODE_FAILED);
  }
}

/* A seek starts over from what is there: a stall or a resume pending from
 * before it no longer applies. */
static void forget_stall(MpxVideo *h) {
  h->stalled = 0;
  h->resume = 0;
  h->avio->eof_reached = 0;
  h->avio->error = 0;
}

int32_t mpx_video_rewind(MpxVideo *h) {
  if (!h) return MPX_VIDEO_INVALID_ARGUMENT;
  forget_stall(h);
  AVStream *st = h->fmt->streams[h->stream];
  int64_t start = st->start_time != AV_NOPTS_VALUE ? st->start_time : 0;
  /* Fallback chain: by timestamp, by a seek window,
   * then by byte offset. */
  int r = av_seek_frame(h->fmt, h->stream, start, AVSEEK_FLAG_BACKWARD);
  if (r < 0) r = avformat_seek_file(h->fmt, h->stream, INT64_MIN, start, start, 0);
  if (r < 0) r = av_seek_frame(h->fmt, h->stream, 0, AVSEEK_FLAG_BYTE);
  if (r < 0 && h->stalled) {
    /* The seek needs bytes that are not there: done by the next next. */
    h->stalled = 0;
    h->resume = 1;
    h->resume_ms = -1;
    return MPX_VIDEO_OK;
  }
  if (r < 0) return spend(h, MPX_VIDEO_DECODE_FAILED);
  avcodec_flush_buffers(h->dec);
  h->state = STATE_RUNNING;
  h->source_failed = 0;
  h->packets = 0;
  h->frames = 0;
  h->skipped = 0;
  h->last_pts_ms = -1;
  h->seek_ms = -1;
  av_frame_unref(h->held);
  return MPX_VIDEO_OK;
}

int32_t mpx_video_seek(MpxVideo *h, int64_t position_ms) {
  if (!h || position_ms < 0) return MPX_VIDEO_INVALID_ARGUMENT;
  forget_stall(h);
  if (position_ms == 0) return mpx_video_rewind(h);
  AVStream *st = h->fmt->streams[h->stream];
  int64_t start = st->start_time != AV_NOPTS_VALUE ? st->start_time : 0;
  int64_t ts = start + av_rescale_q(position_ms, (AVRational){1, 1000}, st->time_base);
  /* To the keyframe at or before the time; a container that cannot seek
   * there goes back to the start, and the frames between are decoded and
   * dropped all the same. */
  int r = av_seek_frame(h->fmt, h->stream, ts, AVSEEK_FLAG_BACKWARD);
  if (r < 0) r = avformat_seek_file(h->fmt, h->stream, INT64_MIN, ts, ts, 0);
  if (r < 0 && h->stalled) {
    h->stalled = 0;
    h->resume = 1;
    h->resume_ms = position_ms - 1;
    return MPX_VIDEO_OK;
  }
  if (r < 0) {
    int32_t rewound = mpx_video_rewind(h);
    if (rewound != MPX_VIDEO_OK) return rewound;
  } else {
    avcodec_flush_buffers(h->dec);
    h->state = STATE_RUNNING;
    h->source_failed = 0;
    h->packets = 0;
    h->frames = 0;
    h->skipped = 0;
    h->last_pts_ms = -1;
    av_frame_unref(h->held);
  }
  h->seek_ms = position_ms;
  return MPX_VIDEO_OK;
}

uint32_t mpx_video_abi_version(void) { return MPX_VIDEO_ABI_VERSION; }
