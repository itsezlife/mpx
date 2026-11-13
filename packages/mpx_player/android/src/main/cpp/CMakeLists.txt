cmake_minimum_required(VERSION 3.10)
project(mpx_player_hbc C)

# The JNI shim over http_bytes_cache's native reader. It links nothing of the
# cache: it calls through the function table whose address Dart hands over.
add_library(mpx_player_hbc SHARED mpx_player_hbc.c)
