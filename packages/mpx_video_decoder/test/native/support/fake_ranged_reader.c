/*
 * A ranged reader table over plain files, for tests: the layout of the bytes
 * cache's hbc_api (version 2), with a test deciding how many bytes of each
 * resource have landed. The cache is not a dependency of the decoder, so its
 * tests compile this one instead (ranged_reader_table.dart).
 *
 * A read of bytes past what landed blocks until they land or the resource
 * is withdrawn, as the real reader does. The decoder reads on a worker
 * thread; the test lands bytes from its own.
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))
#define MAX_RESOURCES 16
#define ERR_CLOSED (-3)
#define ERR_IO (-4)

typedef struct {
  char key[256];
  char path[1024];
  int64_t length;   /* the file's length */
  int64_t landed;   /* bytes [0, landed) may be read */
  int length_known; /* the length is told only once this is set */
  int withdrawn;
  int64_t waits;    /* reads that blocked */
  int64_t opens;
  int64_t open_readers;
} resource;

typedef struct reader {
  resource *r;
  FILE *file;
} reader;

static resource resources[MAX_RESOURCES];
static int count;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;

static resource *find(const char *key) {
  for (int i = 0; i < count; i++) {
    if (strcmp(resources[i].key, key) == 0) return &resources[i];
  }
  return NULL;
}

static reader *reader_open(const char *key) {
  pthread_mutex_lock(&lock);
  resource *r = find(key);
  reader *out = NULL;
  if (r && !r->withdrawn) {
    FILE *file = fopen(r->path, "rb");
    if (file) {
      out = calloc(1, sizeof *out);
      out->r = r;
      out->file = file;
      r->opens++;
      r->open_readers++;
    }
  }
  pthread_mutex_unlock(&lock);
  return out;
}

static int64_t reader_length(reader *rd, int32_t wait) {
  pthread_mutex_lock(&lock);
  resource *r = rd->r;
  while (wait && !r->length_known && !r->withdrawn) {
    r->waits++;
    pthread_cond_wait(&changed, &lock);
  }
  int64_t out = r->withdrawn ? ERR_CLOSED : r->length_known ? r->length : -1;
  pthread_mutex_unlock(&lock);
  return out;
}

static int64_t reader_read(reader *rd, int64_t offset, uint8_t *buffer,
                           int64_t length) {
  pthread_mutex_lock(&lock);
  resource *r = rd->r;
  if (offset >= r->length) {
    pthread_mutex_unlock(&lock);
    return 0;
  }
  while (!r->withdrawn && r->landed <= offset) {
    r->waits++;
    pthread_cond_wait(&changed, &lock);
  }
  if (r->withdrawn) {
    pthread_mutex_unlock(&lock);
    return ERR_CLOSED;
  }
  int64_t n = r->landed - offset;
  pthread_mutex_unlock(&lock);
  if (n > length) n = length;
  if (fseek(rd->file, (long)offset, SEEK_SET) != 0) return ERR_IO;
  size_t got = fread(buffer, 1, (size_t)n, rd->file);
  return got == 0 ? ERR_IO : (int64_t)got;
}

static void reader_set_priority(reader *rd, int32_t priority) {
  (void)rd;
  (void)priority;
}

static void reader_cancel(reader *rd) { (void)rd; }

static void reader_close(reader *rd) {
  pthread_mutex_lock(&lock);
  rd->r->open_readers--;
  pthread_mutex_unlock(&lock);
  fclose(rd->file);
  free(rd);
}

typedef struct {
  int32_t version;
  reader *(*reader_open)(const char *key);
  int64_t (*reader_length)(reader *reader, int32_t wait);
  int64_t (*reader_read)(reader *reader, int64_t offset, uint8_t *buffer,
                         int64_t length);
  void (*reader_set_priority)(reader *reader, int32_t priority);
  void (*reader_cancel)(reader *reader);
  void (*reader_close)(reader *reader);
} api;

static api table = {2,           reader_open,         reader_length,
                    reader_read, reader_set_priority, reader_cancel,
                    reader_close};
static api old_table = {1,           reader_open,         reader_length,
                        reader_read, reader_set_priority, reader_cancel,
                        reader_close};

EXPORT const void *fake_reader_api(void) { return &table; }

EXPORT const void *fake_reader_api_v1(void) { return &old_table; }

/* Publishes [path] as [key] with the first [landed] bytes present; the
 * length is told at once when [length_known]. Returns 0, or -1 when the
 * table is full or the file cannot be read. */
EXPORT int32_t fake_reader_publish(const char *key, const char *path,
                                   int64_t landed, int32_t length_known) {
  FILE *file = fopen(path, "rb");
  if (!file) return -1;
  fseek(file, 0, SEEK_END);
  long length = ftell(file);
  fclose(file);
  pthread_mutex_lock(&lock);
  resource *r = find(key);
  if (!r) {
    if (count == MAX_RESOURCES) {
      pthread_mutex_unlock(&lock);
      return -1;
    }
    r = &resources[count++];
  }
  memset(r, 0, sizeof *r);
  snprintf(r->key, sizeof r->key, "%s", key);
  snprintf(r->path, sizeof r->path, "%s", path);
  r->length = length;
  r->landed = landed < length ? landed : length;
  r->length_known = length_known;
  pthread_cond_broadcast(&changed);
  pthread_mutex_unlock(&lock);
  return 0;
}

static void update(const char *key, int64_t landed, int32_t know,
                   int32_t withdraw) {
  pthread_mutex_lock(&lock);
  resource *r = find(key);
  if (r) {
    if (landed > r->landed) r->landed = landed < r->length ? landed : r->length;
    if (know) r->length_known = 1;
    if (withdraw) r->withdrawn = 1;
    pthread_cond_broadcast(&changed);
  }
  pthread_mutex_unlock(&lock);
}

/* Bytes [0, landed) of [key] are present, and its length is known. */
EXPORT void fake_reader_land(const char *key, int64_t landed) {
  update(key, landed, 1, 0);
}

/* Withdraws [key]: blocked and later reads fail. */
EXPORT void fake_reader_withdraw(const char *key) { update(key, 0, 0, 1); }

static int64_t stat_of(const char *key, int which) {
  pthread_mutex_lock(&lock);
  resource *r = find(key);
  int64_t out = !r                ? -1
                : which == 0      ? r->waits
                : which == 1      ? r->opens
                                  : r->open_readers;
  pthread_mutex_unlock(&lock);
  return out;
}

/* How many reads (and length waits) of [key] blocked. */
EXPORT int64_t fake_reader_waits(const char *key) { return stat_of(key, 0); }

/* How many readers of [key] were opened. */
EXPORT int64_t fake_reader_opens(const char *key) { return stat_of(key, 1); }

/* How many readers of [key] are open now. */
EXPORT int64_t fake_reader_open_readers(const char *key) {
  return stat_of(key, 2);
}
