import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/src/platform/desktop_save_writer.dart';
import 'package:mpx_library/src/platform/xdg_user_dirs.dart';

void main() {
  group('parse', () {
    test('reads the quoted keys, relative to the home or absolute', () {
      final dirs = XdgUserDirs.parse(r'''
# This file is written by xdg-user-dirs-update
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_PICTURES_DIR="/media/data/Pictures"
XDG_VIDEOS_DIR="$HOME/Videos/"
''', home: '/home/u');

      expect(dirs, {
        'XDG_DESKTOP_DIR': '/home/u/Desktop',
        'XDG_DOWNLOAD_DIR': '/home/u/Downloads',
        'XDG_PICTURES_DIR': '/media/data/Pictures',
        'XDG_VIDEOS_DIR': '/home/u/Videos',
      });
    });

    test('a key set to the home is the home', () {
      expect(XdgUserDirs.parse(r'XDG_DOWNLOAD_DIR="$HOME"', home: '/home/u'), {
        'XDG_DOWNLOAD_DIR': '/home/u',
      });
      expect(XdgUserDirs.parse(r'XDG_DOWNLOAD_DIR="$HOME/"', home: '/home/u'), {
        'XDG_DOWNLOAD_DIR': '/home/u',
      });
    });

    test('undoes shell escapes inside the quotes', () {
      expect(
        XdgUserDirs.parse(
          r'XDG_DOWNLOAD_DIR="$HOME/My \"Files\" \$1 \\ x"',
          home: '/home/u',
        ),
        {'XDG_DOWNLOAD_DIR': r'/home/u/My "Files" $1 \ x'},
      );
    });

    test('takes spaces around the sign, an unquoted value and a later '
        'line over an earlier one', () {
      expect(
        XdgUserDirs.parse(
          'XDG_PICTURES_DIR = "/a"\n'
          'XDG_VIDEOS_DIR=/b\n'
          'XDG_PICTURES_DIR="/c"\n',
          home: '/home/u',
        ),
        {'XDG_PICTURES_DIR': '/c', 'XDG_VIDEOS_DIR': '/b'},
      );
    });

    test('skips what the format does not allow: relative paths, other '
        'variables, malformed lines', () {
      expect(
        XdgUserDirs.parse(
          'XDG_DOWNLOAD_DIR="Downloads"\n'
          'XDG_PICTURES_DIR="\$USER/Pictures"\n'
          'XDG_VIDEOS_DIR\n'
          'not a line\n'
          'XDG_MUSIC_DIR="\$HOMEMusic"\n',
          home: '/home/u',
        ),
        isEmpty,
      );
    });
  });

  group('pathOf', () {
    late Directory home;

    setUp(() {
      home = Directory.systemTemp.createTempSync('mpx_xdg_');
      addTearDown(() => home.deleteSync(recursive: true));
    });

    void writeDirs(String configHome, String contents) {
      Directory(configHome).createSync(recursive: true);
      File('$configHome/user-dirs.dirs').writeAsStringSync(contents);
    }

    test('reads user-dirs.dirs from XDG_CONFIG_HOME', () async {
      final config = '${home.path}/conf';
      writeDirs(config, r'XDG_DOWNLOAD_DIR="$HOME/Dl"');
      final dirs = XdgUserDirs(
        environment: {'HOME': home.path, 'XDG_CONFIG_HOME': config},
      );

      expect(await dirs.pathOf(DesktopFolder.downloads), '${home.path}/Dl');
    });

    test('reads it from ~/.config when XDG_CONFIG_HOME is unset, empty or '
        'relative', () async {
      writeDirs('${home.path}/.config', r'XDG_PICTURES_DIR="$HOME/Pics"');
      for (final config in [null, '', 'relative/conf']) {
        final dirs = XdgUserDirs(
          environment: {'HOME': home.path, 'XDG_CONFIG_HOME': ?config},
        );
        expect(await dirs.pathOf(DesktopFolder.pictures), '${home.path}/Pics');
      }
    });

    test('falls back to the home without the file or the key', () async {
      final noFile = XdgUserDirs(environment: {'HOME': home.path});
      expect(await noFile.pathOf(DesktopFolder.videos), home.path);

      writeDirs('${home.path}/.config', r'XDG_DOWNLOAD_DIR="$HOME/Dl"');
      final noKey = XdgUserDirs(environment: {'HOME': home.path});
      expect(await noKey.pathOf(DesktopFolder.videos), home.path);
    });

    test('names no folder without a home', () async {
      expect(
        await XdgUserDirs(environment: {}).pathOf(DesktopFolder.downloads),
        isNull,
      );
    });
  });
}
