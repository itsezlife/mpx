/*
 * Native reader of http_bytes_cache's ranged resources. See the header for
 * the contract; this file keeps the registry of published resources, their
 * range sets, and the blocking reads.
 *
 * One process-wide mutex guards the registry and every range set: the host
 * calls are control messages, and reads hold it only to look up ranges and
 * to wait; the file read itself (pread) runs outside it. Each resource has a
 * condition variable that landings, resets, failures, cancels and unpublish
 * broadcast.
 */
#include "http_bytes_cache.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct hbc_span {
  int64_t start;
  int64_t end;
} hbc_span;

typedef struct hbc_resource {
  int64_t id;
  char *key;
  char *path;
  int64_t total; /* -1 when unknown */
  hbc_span *spans;
  size_t count;
  size_t capacity;
  pthread_cond_t changed;
  int published;
  int readers;
  uint64_t reset_seq;
  uint64_t fail_seq;
  int64_t fail_start;
  int64_t fail_end;
  struct hbc_resource *next;
} hbc_resource;

struct hbc_reader {
  hbc_resource *resource;
  int fd;
  int32_t priority;
  uint64_t cancel_seq;
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static hbc_resource *g_resources = NULL;
static int64_t g_next_id = 1;
static hbc_fetch_fn g_fetch = NULL;

/* --- Registry (g_lock held) --------------------------------------------- */

static hbc_resource *find_by_key(const char *key) {
  for (hbc_resource *r = g_resources; r != NULL; r = r->next) {
    if (strcmp(r->key, key) == 0) return r;
  }
  return NULL;
}

static hbc_resource *find_by_id(int64_t id) {
  for (hbc_resource *r = g_resources; r != NULL; r = r->next) {
    if (r->id == id) return r;
  }
  return NULL;
}

static void unlink_resource(hbc_resource *resource) {
  hbc_resource **link = &g_resources;
  while (*link != NULL && *link != resource) link = &(*link)->next;
  if (*link == resource) *link = resource->next;
  resource->next = NULL;
}

static void free_resource(hbc_resource *resource) {
  pthread_cond_destroy(&resource->changed);
  free(resource->spans);
  free(resource->key);
  free(resource->path);
  free(resource);
}

static char *copy_string(const char *value) {
  size_t length = strlen(value) + 1;
  char *copy = (char *)malloc(length);
  if (copy != NULL) memcpy(copy, value, length);
  return copy;
}

/* --- Range set (g_lock held) -------------------------------------------- */

/* Adds [start, end), merging overlapping and touching spans. Returns 0 when
 * out of memory (the landing is then lost; reads ask again). */
static int add_span(hbc_resource *r, int64_t start, int64_t end) {
  if (end <= start) return 1;
  size_t first = 0;
  while (first < r->count && r->spans[first].end < start) first++;
  size_t last = first;
  while (last < r->count && r->spans[last].start <= end) {
    if (r->spans[last].start < start) start = r->spans[last].start;
    if (r->spans[last].end > end) end = r->spans[last].end;
    last++;
  }
  /* spans[first, last) merge into one span at first. */
  size_t merged = last - first;
  if (merged == 0) {
    if (r->count == r->capacity) {
      size_t capacity = r->capacity == 0 ? 8 : r->capacity * 2;
      hbc_span *grown =
          (hbc_span *)realloc(r->spans, capacity * sizeof(hbc_span));
      if (grown == NULL) return 0;
      r->spans = grown;
      r->capacity = capacity;
    }
    memmove(&r->spans[first + 1], &r->spans[first],
            (r->count - first) * sizeof(hbc_span));
    r->count++;
  } else if (merged > 1) {
    memmove(&r->spans[first + 1], &r->spans[last],
            (r->count - last) * sizeof(hbc_span));
    r->count -= merged - 1;
  }
  r->spans[first].start = start;
  r->spans[first].end = end;
  return 1;
}

/* End of the present bytes running unbroken from [offset]; [offset] when
 * the byte there is missing. */
static int64_t contiguous_from(const hbc_resource *r, int64_t offset) {
  for (size_t i = 0; i < r->count; i++) {
    if (r->spans[i].start <= offset && offset < r->spans[i].end) {
      return r->spans[i].end;
    }
  }
  return offset;
}

static void request_fetch(const hbc_resource *r, int64_t offset,
                          int64_t length, int32_t priority) {
  if (g_fetch != NULL) g_fetch(r->id, offset, length, priority);
}

/* --- Host side ---------------------------------------------------------- */

int32_t hbc_abi_version(void) { return HBC_ABI_VERSION; }

void hbc_set_fetch_callback(hbc_fetch_fn fetch) {
  pthread_mutex_lock(&g_lock);
  g_fetch = fetch;
  pthread_mutex_unlock(&g_lock);
}

int64_t hbc_publish(const char *key, const char *path, int64_t total_length) {
  if (key == NULL || path == NULL) return 0;
  pthread_mutex_lock(&g_lock);
  hbc_resource *r = find_by_key(key);
  if (r != NULL) {
    char *copy = copy_string(path);
    if (copy != NULL) {
      free(r->path);
      r->path = copy;
    }
    if (total_length >= 0) r->total = total_length;
    int64_t id = r->id;
    pthread_cond_broadcast(&r->changed);
    pthread_mutex_unlock(&g_lock);
    return id;
  }
  r = (hbc_resource *)calloc(1, sizeof(hbc_resource));
  if (r == NULL) {
    pthread_mutex_unlock(&g_lock);
    return 0;
  }
  r->key = copy_string(key);
  r->path = copy_string(path);
  if (r->key == NULL || r->path == NULL) {
    free(r->key);
    free(r->path);
    free(r);
    pthread_mutex_unlock(&g_lock);
    return 0;
  }
  pthread_cond_init(&r->changed, NULL);
  r->id = g_next_id++;
  r->total = total_length >= 0 ? total_length : -1;
  r->published = 1;
  r->next = g_resources;
  g_resources = r;
  int64_t id = r->id;
  pthread_mutex_unlock(&g_lock);
  return id;
}

void hbc_set_length(int64_t id, int64_t total_length) {
  pthread_mutex_lock(&g_lock);
  hbc_resource *r = find_by_id(id);
  if (r != NULL && total_length >= 0) {
    r->total = total_length;
    pthread_cond_broadcast(&r->changed);
  }
  pthread_mutex_unlock(&g_lock);
}

void hbc_range_landed(int64_t id, int64_t start, int64_t end) {
  pthread_mutex_lock(&g_lock);
  hbc_resource *r = find_by_id(id);
  if (r != NULL) {
    add_span(r, start, end);
    pthread_cond_broadcast(&r->changed);
  }
  pthread_mutex_unlock(&g_lock);
}

void hbc_ranges_reset(int64_t id) {
  pthread_mutex_lock(&g_lock);
  hbc_resource *r = find_by_id(id);
  if (r != NULL) {
    r->count = 0;
    r->reset_seq++;
    pthread_cond_broadcast(&r->changed);
  }
  pthread_mutex_unlock(&g_lock);
}

void hbc_fetch_failed(int64_t id, int64_t offset, int64_t length) {
  pthread_mutex_lock(&g_lock);
  hbc_resource *r = find_by_id(id);
  if (r != NULL) {
    r->fail_seq++;
    r->fail_start = offset;
    r->fail_end = offset + (length > 0 ? length : 1);
    pthread_cond_broadcast(&r->changed);
  }
  pthread_mutex_unlock(&g_lock);
}

void hbc_unpublish(int64_t id) {
  pthread_mutex_lock(&g_lock);
  hbc_resource *r = find_by_id(id);
  if (r != NULL) {
    unlink_resource(r);
    r->published = 0;
    pthread_cond_broadcast(&r->changed);
    if (r->readers == 0) free_resource(r);
  }
  pthread_mutex_unlock(&g_lock);
}

/* --- Reader side -------------------------------------------------------- */

hbc_reader *hbc_reader_open(const char *key) {
  if (key == NULL) return NULL;
  pthread_mutex_lock(&g_lock);
  hbc_resource *r = find_by_key(key);
  if (r == NULL) {
    pthread_mutex_unlock(&g_lock);
    return NULL;
  }
  int fd;
  do {
    fd = open(r->path, O_RDONLY);
  } while (fd < 0 && errno == EINTR);
  hbc_reader *reader =
      fd < 0 ? NULL : (hbc_reader *)calloc(1, sizeof(hbc_reader));
  if (reader == NULL) {
    if (fd >= 0) close(fd);
    pthread_mutex_unlock(&g_lock);
    return NULL;
  }
  reader->resource = r;
  reader->fd = fd;
  reader->priority = HBC_PRIORITY_VISIBLE;
  r->readers++;
  pthread_mutex_unlock(&g_lock);
  return reader;
}

int64_t hbc_reader_length(hbc_reader *reader, int32_t wait) {
  if (reader == NULL) return HBC_ERR_CLOSED;
  pthread_mutex_lock(&g_lock);
  hbc_resource *r = reader->resource;
  uint64_t cancel = reader->cancel_seq;
  int asked = 0;
  int64_t result;
  for (;;) {
    if (!r->published) {
      result = HBC_ERR_CLOSED;
      break;
    }
    if (r->total >= 0 || !wait) {
      result = r->total;
      break;
    }
    if (reader->cancel_seq != cancel) {
      result = HBC_ERR_CANCELLED;
      break;
    }
    if (!asked) {
      request_fetch(r, 0, 1, reader->priority);
      asked = 1;
    }
    pthread_cond_wait(&r->changed, &g_lock);
  }
  pthread_mutex_unlock(&g_lock);
  return result;
}

int64_t hbc_reader_read(hbc_reader *reader, int64_t offset, uint8_t *buffer,
                        int64_t length) {
  if (reader == NULL) return HBC_ERR_CLOSED;
  if (length <= 0 || offset < 0) return 0;
  pthread_mutex_lock(&g_lock);
  hbc_resource *r = reader->resource;
  uint64_t cancel = reader->cancel_seq;
  uint64_t reset = r->reset_seq;
  uint64_t failures = r->fail_seq;
  int asked = 0;
  int64_t available = 0;
  int64_t result = 0;
  for (;;) {
    if (!r->published) {
      result = HBC_ERR_CLOSED;
      break;
    }
    if (reader->cancel_seq != cancel) {
      result = HBC_ERR_CANCELLED;
      break;
    }
    if (r->total >= 0 && offset >= r->total) {
      result = 0;
      break;
    }
    int64_t end = contiguous_from(r, offset);
    if (end > offset) {
      available = end - offset;
      break;
    }
    if (r->fail_seq != failures) {
      failures = r->fail_seq;
      if (r->fail_start <= offset && offset < r->fail_end) {
        result = HBC_ERR_FAILED;
        break;
      }
    }
    if (r->reset_seq != reset) {
      /* Another representation: whatever was asked may never land. */
      reset = r->reset_seq;
      asked = 0;
    }
    if (!asked) {
      request_fetch(r, offset, length, reader->priority);
      asked = 1;
    }
    pthread_cond_wait(&r->changed, &g_lock);
  }
  pthread_mutex_unlock(&g_lock);
  if (available == 0) return result;

  int64_t want = length < available ? length : available;
  ssize_t got;
  do {
    got = pread(reader->fd, buffer, (size_t)want, (off_t)offset);
  } while (got < 0 && errno == EINTR);
  /* Present bytes are in the file, so a short file is an IO fault. */
  if (got <= 0) return HBC_ERR_IO;
  return (int64_t)got;
}

void hbc_reader_set_priority(hbc_reader *reader, int32_t priority) {
  if (reader == NULL) return;
  pthread_mutex_lock(&g_lock);
  reader->priority = priority;
  pthread_mutex_unlock(&g_lock);
}

void hbc_reader_cancel(hbc_reader *reader) {
  if (reader == NULL) return;
  pthread_mutex_lock(&g_lock);
  reader->cancel_seq++;
  pthread_cond_broadcast(&reader->resource->changed);
  pthread_mutex_unlock(&g_lock);
}

void hbc_reader_close(hbc_reader *reader) {
  if (reader == NULL) return;
  pthread_mutex_lock(&g_lock);
  hbc_resource *r = reader->resource;
  r->readers--;
  if (!r->published && r->readers == 0) free_resource(r);
  pthread_mutex_unlock(&g_lock);
  close(reader->fd);
  free(reader);
}

static const hbc_api g_api = {
    HBC_ABI_VERSION,     hbc_reader_open,   hbc_reader_length,
    hbc_reader_read,     hbc_reader_set_priority, hbc_reader_cancel,
    hbc_reader_close,
};

const hbc_api *hbc_get_api(void) { return &g_api; }
