/*
 * JNI shim between the player's data source (Kotlin) and http_bytes_cache's
 * native reader of ranged resources.
 *
 * The reader is not linked by name: Dart hands over the address of the
 * cache's `hbc_api` function table and every call goes through it. The table
 * layout is mirrored here instead of including the cache's header, because a
 * published plugin cannot reach a sibling package's header by path; the
 * version check keeps the mirror honest.
 */
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>

#define MPX_HBC_ABI_VERSION 2
#define MPX_HBC_CHUNK (256 * 1024)

typedef struct hbc_reader hbc_reader;

/* Mirror of hbc_api (http_bytes_cache.h, HBC_ABI_VERSION 2). */
typedef struct mpx_hbc_api {
  int32_t version;
  hbc_reader *(*reader_open)(const char *key);
  int64_t (*reader_length)(hbc_reader *reader, int32_t wait);
  int64_t (*reader_read)(hbc_reader *reader, int64_t offset, uint8_t *buffer,
                         int64_t length);
  void (*reader_set_priority)(hbc_reader *reader, int32_t priority);
  void (*reader_cancel)(hbc_reader *reader);
  void (*reader_close)(hbc_reader *reader);
} mpx_hbc_api;

static const mpx_hbc_api *api_at(jlong address) {
  return (const mpx_hbc_api *)(intptr_t)address;
}

JNIEXPORT jint JNICALL Java_dev_mpx_player_HbcNative_version(JNIEnv *env,
                                                            jclass cls,
                                                            jlong api) {
  (void)env;
  (void)cls;
  return api == 0 ? 0 : api_at(api)->version;
}

JNIEXPORT jint JNICALL Java_dev_mpx_player_HbcNative_expectedVersion(
    JNIEnv *env, jclass cls) {
  (void)env;
  (void)cls;
  return MPX_HBC_ABI_VERSION;
}

JNIEXPORT jlong JNICALL Java_dev_mpx_player_HbcNative_open(JNIEnv *env,
                                                          jclass cls,
                                                          jlong api,
                                                          jstring key) {
  (void)cls;
  const char *chars = (*env)->GetStringUTFChars(env, key, NULL);
  if (chars == NULL) return 0;
  hbc_reader *reader = api_at(api)->reader_open(chars);
  (*env)->ReleaseStringUTFChars(env, key, chars);
  return (jlong)(intptr_t)reader;
}

JNIEXPORT jlong JNICALL Java_dev_mpx_player_HbcNative_length(JNIEnv *env,
                                                            jclass cls,
                                                            jlong api,
                                                            jlong reader,
                                                            jboolean wait) {
  (void)env;
  (void)cls;
  return api_at(api)->reader_length((hbc_reader *)(intptr_t)reader,
                                    wait ? 1 : 0);
}

/* Blocks while the bytes at [offset] are missing. The read lands in a
 * native buffer and is copied into [buffer] afterwards: a JNI critical
 * section must never block. */
JNIEXPORT jlong JNICALL Java_dev_mpx_player_HbcNative_read(
    JNIEnv *env, jclass cls, jlong api, jlong reader, jlong offset,
    jbyteArray buffer, jint start, jint length) {
  (void)cls;
  if (length <= 0) return 0;
  int64_t wanted = length > MPX_HBC_CHUNK ? MPX_HBC_CHUNK : length;
  uint8_t *native = malloc((size_t)wanted);
  if (native == NULL) return -4; /* HBC_ERR_IO */
  int64_t read = api_at(api)->reader_read((hbc_reader *)(intptr_t)reader,
                                          offset, native, wanted);
  if (read > 0) {
    (*env)->SetByteArrayRegion(env, buffer, start, (jsize)read,
                               (const jbyte *)native);
  }
  free(native);
  return read;
}

JNIEXPORT void JNICALL Java_dev_mpx_player_HbcNative_setPriority(
    JNIEnv *env, jclass cls, jlong api, jlong reader, jint priority) {
  (void)env;
  (void)cls;
  api_at(api)->reader_set_priority((hbc_reader *)(intptr_t)reader, priority);
}

JNIEXPORT void JNICALL Java_dev_mpx_player_HbcNative_cancel(JNIEnv *env,
                                                           jclass cls,
                                                           jlong api,
                                                           jlong reader) {
  (void)env;
  (void)cls;
  api_at(api)->reader_cancel((hbc_reader *)(intptr_t)reader);
}

JNIEXPORT void JNICALL Java_dev_mpx_player_HbcNative_close(JNIEnv *env,
                                                          jclass cls,
                                                          jlong api,
                                                          jlong reader) {
  (void)env;
  (void)cls;
  api_at(api)->reader_close((hbc_reader *)(intptr_t)reader);
}
