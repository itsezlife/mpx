package dev.mpx.player

import androidx.media3.exoplayer.LoadControl
import org.junit.Assert.assertEquals
import org.junit.Test
import java.lang.reflect.Modifier

/**
 * Guards [PreparedLoadControl] against a Media3 release that calls an
 * overload it leaves to the interface's default, which throws: every
 * method of [LoadControl] must be declared by the wrapper.
 */
class PreparedLoadControlTest {
    @Test
    fun forwardsEveryLoadControlMethod() {
        val declared = PreparedLoadControl::class.java.declaredMethods
            .map { it.name to it.parameterTypes.toList() }
            .toSet()
        val missing = LoadControl::class.java.methods
            .filter { !Modifier.isStatic(it.modifiers) }
            .map { it.name to it.parameterTypes.toList() }
            .filter { it !in declared }
            .map { (name, types) -> "$name(${types.joinToString { t -> t.simpleName }})" }
        assertEquals(emptyList<String>(), missing)
    }
}
