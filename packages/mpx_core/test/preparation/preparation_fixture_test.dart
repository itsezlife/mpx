import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

// Lines written by the encoders before they became codecs. A journal or a
// reuse table on a device holds these exact bytes, so every later encoder
// writes them unchanged and every later decoder reads them back.
const _input =
    '{"v":1,"path":"/picked/a.heic","mimeType":"image/heic",'
    '"byteSize":1234}';
const _bareInput =
    '{"v":1,"path":"/picked/b.bin","mimeType":null,'
    '"byteSize":null}';
const _photo = '{"v":1,"as":"photo","highQuality":true}';
const _video = '{"v":1,"as":"video","preset":"veryLow"}';
const _videoNoPreset = '{"v":1,"as":"video","preset":null}';
const _file = '{"v":1,"as":"file"}';
const _prepared =
    '{"v":1,"kind":"video","path":"/out/1.mp4",'
    '"isOriginal":false,"byteSize":5000000,"mimeType":"video/mp4",'
    '"width":1280,"height":720,"durationUs":12345000,'
    '"thumbnailPath":"/out/1.jpg","thumbnailWidth":320,'
    '"thumbnailHeight":180,"hasAudio":true,"animated":false}';
const _original =
    '{"v":1,"kind":"file","path":"/picked/doc.pdf",'
    '"isOriginal":true,"byteSize":42,"mimeType":null,"width":null,'
    '"height":null,"durationUs":null,"thumbnailPath":null,'
    '"thumbnailWidth":null,"thumbnailHeight":null,"hasAudio":false,'
    '"animated":true}';

Map<String, Object?> _read(String line) =>
    (jsonDecode(line) as Map).cast<String, Object?>();

void main() {
  const input = PreparationInput(
    '/picked/a.heic',
    mimeType: 'image/heic',
    byteSize: 1234,
  );
  const bareInput = PreparationInput('/picked/b.bin');
  const photo = PreparationIntent.photo(highQuality: true);
  const video = PreparationIntent.video(preset: CompressionPreset.veryLow);
  const videoNoPreset = PreparationIntent.video();
  const file = PreparationIntent.file();
  const prepared = PreparedMedia(
    kind: PreparedKind.video,
    path: '/out/1.mp4',
    isOriginal: false,
    byteSize: 5000000,
    mimeType: 'video/mp4',
    dimensions: MediaDimensions(1280, 720),
    duration: Duration(milliseconds: 12345),
    thumbnailPath: '/out/1.jpg',
    thumbnailDimensions: MediaDimensions(320, 180),
    hasAudio: true,
  );
  const original = PreparedMedia(
    kind: PreparedKind.file,
    path: '/picked/doc.pdf',
    isOriginal: true,
    byteSize: 42,
    animated: true,
  );

  test('the encoders write the stored lines byte for byte', () {
    expect(jsonEncode(PreparationEncoding.encodeInput(input)), _input);
    expect(jsonEncode(PreparationEncoding.encodeInput(bareInput)), _bareInput);
    expect(jsonEncode(PreparationEncoding.encodeIntent(photo)), _photo);
    expect(jsonEncode(PreparationEncoding.encodeIntent(video)), _video);
    expect(
      jsonEncode(PreparationEncoding.encodeIntent(videoNoPreset)),
      _videoNoPreset,
    );
    expect(jsonEncode(PreparationEncoding.encodeIntent(file)), _file);
    expect(jsonEncode(PreparationEncoding.encodePrepared(prepared)), _prepared);
    expect(jsonEncode(PreparationEncoding.encodePrepared(original)), _original);
  });

  test('the decoders read the stored lines back', () {
    expect(PreparationEncoding.decodeInput(_read(_input)), input);
    expect(PreparationEncoding.decodeInput(_read(_bareInput)), bareInput);
    expect(PreparationEncoding.decodeIntent(_read(_photo)), photo);
    expect(PreparationEncoding.decodeIntent(_read(_video)), video);
    expect(
      PreparationEncoding.decodeIntent(_read(_videoNoPreset)),
      videoNoPreset,
    );
    expect(PreparationEncoding.decodeIntent(_read(_file)), file);
    expect(PreparationEncoding.decodePrepared(_read(_prepared)), prepared);
    expect(PreparationEncoding.decodePrepared(_read(_original)), original);
  });
}
