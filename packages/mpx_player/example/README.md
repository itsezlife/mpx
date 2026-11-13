# mpx_player example

Plays a bundled clip with sound on the platform player (AVPlayer on iOS and
macOS, Media3 on Android). The clip is served from a loopback origin and read
through `http_bytes_cache`'s native reader, as a host's CDN bytes would be.

```shell
flutter run -d macos
# The PlayerEngine contract on the real backend:
flutter test integration_test -d macos
```
