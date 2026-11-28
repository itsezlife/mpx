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
    expect(jsonEncode(const PreparationInputCodec().encode(input)), _input);
    expect(
      jsonEncode(const PreparationInputCodec().encode(bareInput)),
      _bareInput,
    );
    expect(jsonEncode(const PreparationIntentCodec().encode(photo)), _photo);
    expect(jsonEncode(const PreparationIntentCodec().encode(video)), _video);
    expect(
      jsonEncode(const PreparationIntentCodec().encode(videoNoPreset)),
      _videoNoPreset,
    );
    expect(jsonEncode(const PreparationIntentCodec().encode(file)), _file);
    expect(jsonEncode(const PreparedMediaCodec().encode(prepared)), _prepared);
    expect(jsonEncode(const PreparedMediaCodec().encode(original)), _original);
  });

  test('the decoders read the stored lines back', () {
    expect(const PreparationInputCodec().decode(_read(_input)), input);
    expect(const PreparationInputCodec().decode(_read(_bareInput)), bareInput);
    expect(const PreparationIntentCodec().decode(_read(_photo)), photo);
    expect(const PreparationIntentCodec().decode(_read(_video)), video);
    expect(
      const PreparationIntentCodec().decode(_read(_videoNoPreset)),
      videoNoPreset,
    );
    expect(const PreparationIntentCodec().decode(_read(_file)), file);
    expect(const PreparedMediaCodec().decode(_read(_prepared)), prepared);
    expect(const PreparedMediaCodec().decode(_read(_original)), original);
  });
}
