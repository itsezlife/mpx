import 'package:test/test.dart';

import 'cache/cache_logger_middleware_test.dart'
    as cache_logger_middleware_test;
import 'cache/cache_middleware_test.dart' as cache_middleware_test;
import 'cache/cache_test.dart' as cache_test;
import 'cache/indexed_cache_test.dart' as indexed_cache_test;
import 'cache/skip_cache_middleware_test.dart' as skip_cache_middleware_test;
import 'native/native_reader_test.dart' as native_reader_test;
import 'open/open_test.dart' as open_test;
import 'ranged/byte_range_set_test.dart' as byte_range_set_test;
import 'ranged/fast_start_test.dart' as fast_start_test;
import 'ranged/ranged_alias_test.dart' as ranged_alias_test;
import 'ranged/ranged_resource_test.dart' as ranged_resource_test;
import 'ranged/ranged_store_test.dart' as ranged_store_test;
import 'resolve/bearer_middleware_test.dart' as bearer_middleware_test;
import 'resolve/client_test.dart' as client_test;
import 'resolve/conditional_middleware_test.dart'
    as conditional_middleware_test;
import 'resolve/freshness_test.dart' as freshness_test;
import 'resolve/logger_middleware_test.dart' as logger_middleware_test;
import 'resolve/peek_test.dart' as peek_test;
import 'resolve/pipeline_test.dart' as pipeline_test;
import 'resolve/priority_test.dart' as priority_test;
import 'resolve/progress_fanout_test.dart' as progress_fanout_test;
import 'resolve/range_request_test.dart' as range_request_test;
import 'resolve/resolver_test.dart' as resolver_test;
import 'resolve/swr_test.dart' as swr_test;
import 'storage/blob_store_vm_test.dart' as blob_store_vm_test;
import 'storage/web_store_test.dart' as web_store_test;
import 'store/alias_test.dart' as alias_test;
import 'store/file_lease_test.dart' as file_lease_test;
import 'store/quotas_test.dart' as quotas_test;
import 'store/registered_quotas_test.dart' as registered_quotas_test;
import 'store/store_contract_test.dart' as store_contract_test;

/// Single aggregate entrypoint for VM unit + integration suites.
///
/// Chrome-only open coverage stays out of this file — run
/// `test/open/open_web_test.dart` with `--platform chrome`.
void main() => group('Unit', () {
  cache_test.main();
  cache_middleware_test.main();
  skip_cache_middleware_test.main();
  cache_logger_middleware_test.main();
  indexed_cache_test.main();
  open_test.main();
  resolver_test.main();
  freshness_test.main();
  client_test.main();
  pipeline_test.main();
  progress_fanout_test.main();
  peek_test.main();
  priority_test.main();
  swr_test.main();
  range_request_test.main();
  bearer_middleware_test.main();
  conditional_middleware_test.main();
  logger_middleware_test.main();
  blob_store_vm_test.main();
  web_store_test.main();
  store_contract_test.main();
  file_lease_test.main();
  quotas_test.main();
  registered_quotas_test.main();
  alias_test.main();
  byte_range_set_test.main();
  ranged_store_test.main();
  ranged_resource_test.main();
  fast_start_test.main();
  ranged_alias_test.main();
  native_reader_test.main();
});
