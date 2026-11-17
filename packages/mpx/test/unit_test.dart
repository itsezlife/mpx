/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'download/network_auto_download_policy_test.dart'
    as network_auto_download_policy_test;
import 'fetch/bytes_cache_fetcher_files_test.dart'
    as bytes_cache_fetcher_files_test;
import 'fetch/bytes_cache_fetcher_test.dart' as bytes_cache_fetcher_test;
import 'signals/device_signals_test.dart' as device_signals_test;
import 'signals/fake_device_signals_test.dart' as fake_device_signals_test;
import 'stack/mpx_stack_test.dart' as mpx_stack_test;

void main() {
  group('bytes_cache_fetcher_files_test', bytes_cache_fetcher_files_test.main);
  group('bytes_cache_fetcher_test', bytes_cache_fetcher_test.main);
  group(
    'network_auto_download_policy_test',
    network_auto_download_policy_test.main,
  );
  group('device_signals_test', device_signals_test.main);
  group('fake_device_signals_test', fake_device_signals_test.main);
  group('mpx_stack_test', mpx_stack_test.main);
}
