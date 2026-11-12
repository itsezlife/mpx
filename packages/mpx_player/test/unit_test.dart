/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'backend/fake_player_engine_contract_test.dart'
    as fake_player_engine_contract_test;
import 'feed/feed_list_policy_test.dart' as feed_list_policy_test;
import 'pool/player_pool_test.dart' as player_pool_test;
import 'widget/player_view_test.dart' as player_view_test;

void main() {
  group(
    'fake_player_engine_contract_test',
    fake_player_engine_contract_test.main,
  );
  group('feed_list_policy_test', feed_list_policy_test.main);
  group('player_pool_test', player_pool_test.main);
  group('player_view_test', player_view_test.main);
}
