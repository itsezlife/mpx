package dev.mpx.capture

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * The GL stage of round video: one EGL context that draws the camera's
 * external texture, cropped to its centre square, rotated upright and
 * mirrored for the front camera, into any number of window surfaces (the
 * encoder's input and the preview). Every call runs on the thread that
 * created it.
 */
class GlStage {
    private val display: EGLDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    private val config: EGLConfig
    private val context: EGLContext
    private val idle: EGLSurface
    private val program: Int
    private val positionLocation: Int
    private val texCoordLocation: Int
    private val texMatrixLocation: Int
    private val quad: FloatBuffer = floatBuffer(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
    private val texCoords: FloatBuffer = floatBuffer(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
    private val matrix = FloatArray(16)

    init {
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] > 0) {
            "no recordable EGL config"
        }
        config = configs[0]!!
        context = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
        idle = EGL14.eglCreatePbufferSurface(
            display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
        )
        makeCurrent(idle)
        program = link(VERTEX_SHADER, FRAGMENT_SHADER)
        positionLocation = GLES20.glGetAttribLocation(program, "aPosition")
        texCoordLocation = GLES20.glGetAttribLocation(program, "aTexCoord")
        texMatrixLocation = GLES20.glGetUniformLocation(program, "uTexMatrix")
    }

    /** A window surface over [surface]. */
    fun windowSurface(surface: Surface): EGLSurface =
        EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)

    fun releaseSurface(surface: EGLSurface) {
        makeCurrent(idle)
        EGL14.eglDestroySurface(display, surface)
    }

    /** A new external texture for a camera SurfaceTexture. */
    fun externalTexture(): Int {
        makeCurrent(idle)
        val names = IntArray(1)
        GLES20.glGenTextures(1, names, 0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, names[0])
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return names[0]
    }

    fun deleteTexture(texture: Int) {
        makeCurrent(idle)
        GLES20.glDeleteTextures(1, intArrayOf(texture), 0)
    }

    /**
     * Draws [texture] into [target] at [side] × [side]. [surfaceMatrix] is the
     * SurfaceTexture's transform; [bufferWidth] × [bufferHeight] the camera
     * buffer, which [rotationDegrees] (clockwise) turns upright, [turnDegrees]
     * of it applied here (the rest is in [surfaceMatrix]). With
     * [presentationNs] the frame gets that timestamp (the encoder's surface).
     */
    fun draw(
        target: EGLSurface,
        side: Int,
        texture: Int,
        surfaceMatrix: FloatArray,
        bufferWidth: Int,
        bufferHeight: Int,
        rotationDegrees: Int,
        turnDegrees: Int,
        mirrored: Boolean,
        presentationNs: Long? = null,
    ) {
        makeCurrent(target)
        GLES20.glViewport(0, 0, side, side)
        GLES20.glUseProgram(program)
        displayToTexture(surfaceMatrix, bufferWidth, bufferHeight, rotationDegrees, turnDegrees, mirrored)
        GLES20.glUniformMatrix4fv(texMatrixLocation, 1, false, matrix, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glEnableVertexAttribArray(positionLocation)
        GLES20.glVertexAttribPointer(positionLocation, 2, GLES20.GL_FLOAT, false, 0, quad)
        GLES20.glEnableVertexAttribArray(texCoordLocation)
        GLES20.glVertexAttribPointer(texCoordLocation, 2, GLES20.GL_FLOAT, false, 0, texCoords)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        if (presentationNs != null) EGLExt.eglPresentationTimeANDROID(display, target, presentationNs)
        EGL14.eglSwapBuffers(display, target)
    }

    /**
     * Draws [texture] whole into [target] at [width] × [height], through the
     * SurfaceTexture's [surfaceMatrix] only: the frame as a SurfaceTexture
     * consumer would show it. With [presentationNs] the frame gets that
     * timestamp (an encoder's surface).
     */
    fun drawWhole(
        target: EGLSurface,
        width: Int,
        height: Int,
        texture: Int,
        surfaceMatrix: FloatArray,
        presentationNs: Long? = null,
    ) {
        makeCurrent(target)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glUseProgram(program)
        GLES20.glUniformMatrix4fv(texMatrixLocation, 1, false, surfaceMatrix, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glEnableVertexAttribArray(positionLocation)
        GLES20.glVertexAttribPointer(positionLocation, 2, GLES20.GL_FLOAT, false, 0, quad)
        GLES20.glEnableVertexAttribArray(texCoordLocation)
        GLES20.glVertexAttribPointer(texCoordLocation, 2, GLES20.GL_FLOAT, false, 0, texCoords)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        if (presentationNs != null) EGLExt.eglPresentationTimeANDROID(display, target, presentationNs)
        EGL14.eglSwapBuffers(display, target)
    }

    // Maps a coordinate of the upright output square to the camera texture:
    // texture = surfaceMatrix · (centre + rotate(t) · mirror · crop · (d − centre)).
    // The crop keeps the centre square of the upright frame (its shape set by
    // the whole rotation); rotating the upright coordinate counter-clockwise
    // by t, the part of the rotation the matrix does not carry, finds it.
    private fun displayToTexture(
        surfaceMatrix: FloatArray,
        bufferWidth: Int,
        bufferHeight: Int,
        rotationDegrees: Int,
        turnDegrees: Int,
        mirrored: Boolean,
    ) {
        val quarterTurn = rotationDegrees % 180 != 0
        val uprightWidth = (if (quarterTurn) bufferHeight else bufferWidth).toFloat()
        val uprightHeight = (if (quarterTurn) bufferWidth else bufferHeight).toFloat()
        val square = minOf(uprightWidth, uprightHeight)
        val local = FloatArray(16)
        Matrix.setIdentityM(local, 0)
        Matrix.translateM(local, 0, 0.5f, 0.5f, 0f)
        Matrix.rotateM(local, 0, turnDegrees.toFloat(), 0f, 0f, 1f)
        Matrix.scaleM(local, 0, (if (mirrored) -1f else 1f) * square / uprightWidth, square / uprightHeight, 1f)
        Matrix.translateM(local, 0, -0.5f, -0.5f, 0f)
        Matrix.multiplyMM(matrix, 0, surfaceMatrix, 0, local, 0)
    }

    private fun makeCurrent(surface: EGLSurface) {
        check(EGL14.eglMakeCurrent(display, surface, surface, context)) { "eglMakeCurrent failed" }
    }

    fun release() {
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(display, idle)
        EGL14.eglDestroyContext(display, context)
        EGL14.eglReleaseThread()
        EGL14.eglTerminate(display)
    }

    private fun link(vertex: String, fragment: String): Int {
        fun compile(type: Int, source: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val status = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
            check(status[0] != 0) { "shader: ${GLES20.glGetShaderInfoLog(shader)}" }
            return shader
        }
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, compile(GLES20.GL_VERTEX_SHADER, vertex))
        GLES20.glAttachShader(program, compile(GLES20.GL_FRAGMENT_SHADER, fragment))
        GLES20.glLinkProgram(program)
        val status = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
        check(status[0] != 0) { "program: ${GLES20.glGetProgramInfoLog(program)}" }
        return program
    }

    private companion object {
        const val EGL_RECORDABLE_ANDROID = 0x3142

        const val VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            uniform mat4 uTexMatrix;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uTexMatrix * aTexCoord).xy;
            }
        """

        const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTexCoord);
            }
        """

        fun floatBuffer(vararg values: Float): FloatBuffer =
            ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                put(values)
                position(0)
            }
    }
}
