// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'mastodon_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

StatusDto _$StatusDtoFromJson(Map<String, dynamic> json) => StatusDto(
  id: json['id'] as String,
  createdAt: DateTime.parse(json['created_at'] as String),
  content: json['content'] as String,
  account: AccountDto.fromJson(json['account'] as Map<String, dynamic>),
  url: json['url'] as String?,
  sensitive: json['sensitive'] as bool? ?? false,
  spoilerText: json['spoiler_text'] as String? ?? '',
  reblog: json['reblog'] == null
      ? null
      : StatusDto.fromJson(json['reblog'] as Map<String, dynamic>),
  mediaAttachments:
      (json['media_attachments'] as List<dynamic>?)
          ?.map((e) => MediaAttachmentDto.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  repliesCount: (json['replies_count'] as num?)?.toInt() ?? 0,
  reblogsCount: (json['reblogs_count'] as num?)?.toInt() ?? 0,
  favouritesCount: (json['favourites_count'] as num?)?.toInt() ?? 0,
);

AccountDto _$AccountDtoFromJson(Map<String, dynamic> json) => AccountDto(
  id: json['id'] as String,
  acct: json['acct'] as String,
  username: json['username'] as String? ?? '',
  displayName: json['display_name'] as String? ?? '',
  avatar: json['avatar'] as String?,
  bot: json['bot'] as bool? ?? false,
);

MediaAttachmentDto _$MediaAttachmentDtoFromJson(Map<String, dynamic> json) =>
    MediaAttachmentDto(
      id: json['id'] as String,
      type:
          $enumDecodeNullable(
            _$MediaAttachmentTypeEnumMap,
            json['type'],
            unknownValue: MediaAttachmentType.unknown,
          ) ??
          MediaAttachmentType.unknown,
      url: json['url'] as String?,
      previewUrl: json['preview_url'] as String?,
      description: json['description'] as String?,
      meta: json['meta'] == null
          ? null
          : MediaMetaDto.fromJson(json['meta'] as Map<String, dynamic>),
    );

const _$MediaAttachmentTypeEnumMap = {
  MediaAttachmentType.image: 'image',
  MediaAttachmentType.video: 'video',
  MediaAttachmentType.gifv: 'gifv',
  MediaAttachmentType.audio: 'audio',
  MediaAttachmentType.unknown: 'unknown',
};

MediaMetaDto _$MediaMetaDtoFromJson(Map<String, dynamic> json) => MediaMetaDto(
  original: json['original'] == null
      ? null
      : MediaSizeDto.fromJson(json['original'] as Map<String, dynamic>),
);

MediaSizeDto _$MediaSizeDtoFromJson(Map<String, dynamic> json) => MediaSizeDto(
  width: (json['width'] as num?)?.toInt(),
  height: (json['height'] as num?)?.toInt(),
  duration: (json['duration'] as num?)?.toDouble(),
  bitrate: (json['bitrate'] as num?)?.toInt(),
);
