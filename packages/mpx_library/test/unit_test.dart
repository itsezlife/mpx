/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'fetch/library_fetcher_test.dart' as library_fetcher_test;
import 'identity/library_keys_test.dart' as library_keys_test;
import 'intake/fake_drop_intake_contract_test.dart'
    as fake_drop_intake_contract_test;
import 'intake/fake_file_intake_contract_test.dart'
    as fake_file_intake_contract_test;
import 'intake/intake_test.dart' as intake_test;
import 'library/fake_media_library_contract_test.dart'
    as fake_media_library_contract_test;
import 'library/fake_media_library_test.dart' as fake_media_library_test;
import 'platform/apple_save_writer_test.dart' as apple_save_writer_test;
import 'platform/desktop_save_writer_test.dart' as desktop_save_writer_test;
import 'platform/platform_media_library_test.dart'
    as platform_media_library_test;
import 'platform/platform_media_saver_test.dart' as platform_media_saver_test;
import 'platform/platform_save_access_test.dart' as platform_save_access_test;
import 'platform/windows_known_folders_test.dart' as windows_known_folders_test;
import 'platform/xdg_user_dirs_test.dart' as xdg_user_dirs_test;
import 'save/fake_media_saver_contract_test.dart'
    as fake_media_saver_contract_test;
import 'save/fake_media_saver_test.dart' as fake_media_saver_test;
import 'save/save_content_test.dart' as save_content_test;
import 'save/save_diagnostics_test.dart' as save_diagnostics_test;

void main() {
  group('library_fetcher_test', library_fetcher_test.main);
  group('library_keys_test', library_keys_test.main);
  group('fake_drop_intake_contract_test', fake_drop_intake_contract_test.main);
  group('fake_file_intake_contract_test', fake_file_intake_contract_test.main);
  group('intake_test', intake_test.main);
  group(
    'fake_media_library_contract_test',
    fake_media_library_contract_test.main,
  );
  group('fake_media_library_test', fake_media_library_test.main);
  group('apple_save_writer_test', apple_save_writer_test.main);
  group('desktop_save_writer_test', desktop_save_writer_test.main);
  group('platform_media_library_test', platform_media_library_test.main);
  group('platform_media_saver_test', platform_media_saver_test.main);
  group('platform_save_access_test', platform_save_access_test.main);
  group('windows_known_folders_test', windows_known_folders_test.main);
  group('xdg_user_dirs_test', xdg_user_dirs_test.main);
  group('fake_media_saver_contract_test', fake_media_saver_contract_test.main);
  group('fake_media_saver_test', fake_media_saver_test.main);
  group('save_content_test', save_content_test.main);
  group('save_diagnostics_test', save_diagnostics_test.main);
}
