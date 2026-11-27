/// What the transfers demo does that differs between the VM and the web,
/// decided by which file the build picks.
library;

export 'transfers_host_vm.dart'
    if (dart.library.js_interop) 'transfers_host_js.dart';
