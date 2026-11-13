package dev.mpx.player

/**
 * The bytes cache's native reader of ranged resources, reached through the
 * function table at the address Dart hands over (`api`). Reads block while
 * bytes are missing: call them on a loader thread, never on the main one.
 */
internal object HbcNative {
    init {
        System.loadLibrary("mpx_player_hbc")
    }

    /** Read results below zero, as the reader returns them. */
    const val ERR_CANCELLED = -1L
    const val ERR_FAILED = -2L
    const val ERR_CLOSED = -3L
    const val ERR_IO = -4L

    /** The table version at [api]; 0 for a null address. */
    @JvmStatic external fun version(api: Long): Int

    /** The table version this shim mirrors. */
    @JvmStatic external fun expectedVersion(): Int

    /** A reader of the published resource [key], or 0 when unpublished. */
    @JvmStatic external fun open(api: Long, key: String): Long

    @JvmStatic external fun length(api: Long, reader: Long, wait: Boolean): Long

    @JvmStatic
    external fun read(
        api: Long,
        reader: Long,
        offset: Long,
        buffer: ByteArray,
        start: Int,
        length: Int,
    ): Long

    @JvmStatic external fun setPriority(api: Long, reader: Long, priority: Int)

    @JvmStatic external fun cancel(api: Long, reader: Long)

    @JvmStatic external fun close(api: Long, reader: Long)
}
