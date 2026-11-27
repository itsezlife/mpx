#include "include/mpx_transfer/mpx_transfer_plugin.h"

// The native part of mpx_transfer on Linux. Empty: Linux has no OS envelope,
// so `system` transfers run in process, and the transfer engine runs in Dart.
void mpx_transfer_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
}
