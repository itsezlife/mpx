# The Flutter tooling requires CMake 3.10 or later on Linux; do not raise it.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "mpx_transfer")
project(${PROJECT_NAME} LANGUAGES CXX)

# Used by the Flutter tooling; must not change.
set(PLUGIN_NAME "mpx_transfer_plugin")

add_library(${PLUGIN_NAME} SHARED
  "mpx_transfer_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

set(mpx_transfer_bundled_libraries
  ""
  PARENT_SCOPE
)
