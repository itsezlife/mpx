import 'package:json_annotation/json_annotation.dart';

part 'mastodon_dto.g.dart';

/// What a Mastodon server sends of one status (`/api/v1/statuses`), the
/// fields the feed reads. Decoded by generated code; the adapter maps it.
@JsonSerializable(createToJson: false)
class StatusDto {
  const StatusDto({
    required this.id,
    required this.createdAt,
    required this.content,
    required this.account,
    this.url,
    this.sensitive = false,
    this.spoilerText = '',
    this.reblog,
    this.mediaAttachments = const [],
    this.repliesCount = 0,
    this.reblogsCount = 0,
    this.favouritesCount = 0,
  });

  factory StatusDto.fromJson(Map<String, Object?> json) =>
      _$StatusDtoFromJson(json);

  final String id;
  final DateTime createdAt;

  /// HTML.
  final String content;

  final AccountDto account;
  final String? url;
  final bool sensitive;
  final String spoilerText;

  /// The status this one boosts, when it is a boost.
  final StatusDto? reblog;

  final List<MediaAttachmentDto> mediaAttachments;
  final int repliesCount;
  final int reblogsCount;
  final int favouritesCount;
}

@JsonSerializable(createToJson: false)
class AccountDto {
  const AccountDto({
    required this.id,
    required this.acct,
    this.username = '',
    this.displayName = '',
    this.avatar,
    this.bot = false,
  });

  factory AccountDto.fromJson(Map<String, Object?> json) =>
      _$AccountDtoFromJson(json);

  final String id;

  /// `name` for an account of the server asked, `name@server` otherwise.
  final String acct;

  final String username;
  final String displayName;
  final String? avatar;
  final bool bot;
}

@JsonEnum()
enum MediaAttachmentType { image, video, gifv, audio, unknown }

@JsonSerializable(createToJson: false)
class MediaAttachmentDto {
  const MediaAttachmentDto({
    required this.id,
    this.type = MediaAttachmentType.unknown,
    this.url,
    this.previewUrl,
    this.description,
    this.meta,
  });

  factory MediaAttachmentDto.fromJson(Map<String, Object?> json) =>
      _$MediaAttachmentDtoFromJson(json);

  final String id;

  @JsonKey(unknownEnumValue: MediaAttachmentType.unknown)
  final MediaAttachmentType type;

  final String? url;
  final String? previewUrl;
  final String? description;
  final MediaMetaDto? meta;
}

@JsonSerializable(createToJson: false)
class MediaMetaDto {
  const MediaMetaDto({this.original});

  factory MediaMetaDto.fromJson(Map<String, Object?> json) =>
      _$MediaMetaDtoFromJson(json);

  final MediaSizeDto? original;
}

@JsonSerializable(createToJson: false)
class MediaSizeDto {
  const MediaSizeDto({this.width, this.height, this.duration, this.bitrate});

  factory MediaSizeDto.fromJson(Map<String, Object?> json) =>
      _$MediaSizeDtoFromJson(json);

  final int? width;
  final int? height;

  /// Seconds.
  final double? duration;

  /// Bits per second.
  final int? bitrate;
}
