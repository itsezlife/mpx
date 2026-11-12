# libmpx_frame_texture.so: the texture table (native/src/mpx_frame_texture.c) and its
# JNI side. Built by the Android Gradle Plugin with the app's NDK, so the
# plugin's Kotlin and the library ship in one module; the Dart side opens the
# same file by name (lib/src/ffi_frame_texture_natives.dart).
cmake_minimum_required(VERSION 3.10)
project(mpx_frame_texture C)

set(NATIVE ${CMAKE_CURRENT_SOURCE_DIR}/../native)

add_library(mpx_frame_texture SHARED
  ${NATIVE}/src/mpx_frame_texture.c
  ${NATIVE}/src/mpx_frame_texture_jni.c
)
target_include_directories(mpx_frame_texture PRIVATE ${NATIVE}/include)
set_target_properties(mpx_frame_texture PROPERTIES C_STANDARD 11 C_VISIBILITY_PRESET hidden)
target_compile_options(mpx_frame_texture PRIVATE -Wall -Wextra -Werror -O2)
# 16 KB page alignment; NDK r28 defaults to it, older ones do not.
target_link_options(mpx_frame_texture PRIVATE -Wl,-z,max-page-size=16384)
target_link_libraries(mpx_frame_texture android)
