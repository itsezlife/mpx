/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'audio/audio_focus_contract_test.dart' as audio_focus_contract_test;
import 'audio/audio_owner_test.dart' as audio_owner_test;
import 'backend/fake_player_engine_contract_test.dart'
    as fake_player_engine_contract_test;
import 'budget/player_device_test.dart' as player_device_test;
import 'feed/feed_controller_test.dart' as feed_controller_test;
import 'feed/feed_list_policy_test.dart' as feed_list_policy_test;
import 'feed/feed_pager_test.dart' as feed_pager_test;
import 'feed/feed_signals_test.dart' as feed_signals_test;
import 'feed/feed_slot_test.dart' as feed_slot_test;
import 'native/native_player_backend_test.dart' as native_player_backend_test;
import 'pool/handoff_test.dart' as handoff_test;
import 'pool/picture_in_picture_test.dart' as picture_in_picture_test;
import 'pool/player_pool_test.dart' as player_pool_test;
import 'widget/player_view_test.dart' as player_view_test;

void main() {
  group('audio_focus_contract_test', audio_focus_contract_test.main);
  group('audio_owner_test', audio_owner_test.main);
  group(
    'fake_player_engine_contract_test',
    fake_player_engine_contract_test.main,
  );
  group('player_device_test', player_device_test.main);
  group('feed_controller_test', feed_controller_test.main);
  group('feed_list_policy_test', feed_list_policy_test.main);
  group('feed_pager_test', feed_pager_test.main);
  group('feed_signals_test', feed_signals_test.main);
  group('feed_slot_test', feed_slot_test.main);
  group('native_player_backend_test', native_player_backend_test.main);
  group('handoff_test', handoff_test.main);
  group('picture_in_picture_test', picture_in_picture_test.main);
  group('player_pool_test', player_pool_test.main);
  group('player_view_test', player_view_test.main);
}
