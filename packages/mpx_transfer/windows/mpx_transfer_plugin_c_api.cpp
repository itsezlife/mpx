#include "include/mpx_transfer/mpx_transfer_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace {

// The native part of mpx_transfer on Windows. Empty: Windows has no OS
// envelope, so `system` transfers run in process, and the transfer engine
// runs in Dart.
class MpxTransferPlugin : public flutter::Plugin {
 public:
  MpxTransferPlugin() = default;
  ~MpxTransferPlugin() override = default;

  MpxTransferPlugin(const MpxTransferPlugin&) = delete;
  MpxTransferPlugin& operator=(const MpxTransferPlugin&) = delete;
};

}  // namespace

void MpxTransferPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar)
      ->AddPlugin(std::make_unique<MpxTransferPlugin>());
}
