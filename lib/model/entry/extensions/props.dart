import 'dart:io';
import 'dart:ui';

import 'package:purer/locale/purer_locale.dart';
import 'package:purer/model/app/support.dart';
import 'package:purer/model/entry/entry.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/ref/mime_types.dart';
import 'package:purer/ref/unicode.dart';
import 'package:purer/services/common/services.dart';
import 'package:purer/theme/text.dart';
import 'package:purer/utils/cloud_url.dart';

extension ExtraPurerEntryProps on PurerEntry {
  bool get isValid => !isMissingAtPath && sizeBytes != 0 && width > 0 && height > 0;

  // type

  String get mimeTypeAnySubtype => mimeType.replaceAll(RegExp('/.*'), '/*');

  bool get canHaveAlpha => MimeTypes.canHaveAlpha(mimeType);

  bool get isSvg => mimeType == MimeTypes.svg;

  bool get isRaw => MimeTypes.isRaw(mimeType);

  bool get isImage => MimeTypes.isImage(mimeType);

  bool get isVideo => MimeTypes.isVideo(mimeType) || (mimeType == MimeTypes.avif && isAnimated);

  bool get isPureVideo => isVideo && !isAnimated;

  // remote

  bool get isRemote => isCloudUri(uri);

  // size

  bool get useTiles => !isRemote && !isAnimated;

  bool get isSized => width > 0 && height > 0;

  Size videoDisplaySize(double? sar) {
    final size = displaySize;
    if (sar != null && sar != 1) {
      final dar = displayAspectRatio * sar;
      final w = size.width;
      final h = size.height;
      if (w >= h) return Size(w, w / dar);
      if (h > w) return Size(h * dar, h);
    }
    return size;
  }

  // text

  String getResolutionText(PurerLocale locale) {
    final dimensionFormatter = locale.numberFormat('0');
    final ws = dimensionFormatter.format(width);
    final hs = dimensionFormatter.format(height);
    return isRotated ? '$hs${AText.resolutionSeparator}$ws' : '$ws${AText.resolutionSeparator}$hs';
  }

  String get aspectRatioText {
    const separator = UniChars.ratio;
    if (width > 0 && height > 0) {
      final gcd = width.gcd(height);
      final w = width ~/ gcd;
      final h = height ~/ gcd;
      return isRotated ? '$h$separator$w' : '$w$separator$h';
    } else {
      return '${AText.valueNotAvailable}$separator${AText.valueNotAvailable}';
    }
  }

  // catalog

  bool get isGeotiff => catalogMetadata?.isGeotiff ?? false;

  bool get is360 => catalogMetadata?.is360 ?? false;

  // storage

  String? get storagePath {
    // remote entries have no local storage path
    if (isRemote) return null;
    if (trashed) {
      final _storagePath = trashDetails?.path;
      if (_storagePath != null) {
        return _storagePath;
      } else {
        // for trashed items which are for some reason missing trash details,
        // do not fall back to original item path,
        // but derive storage path from `file` URI
        final _uri = Uri.parse(uri);
        return _uri.scheme == 'file' ? _uri.path : null;
      }
    } else {
      return path;
    }
  }

  // storage directory path, without the trailing separator
  String? get storageDirectory {
    if (!trashed) {
      // prefer normalized paths
      return directory;
    }
    final _storagePath = storagePath;
    return _storagePath != null ? pContext.dirname(_storagePath) : null;
  }

  bool get isMissingAtPath {
    // remote entries are not checked against the local file system
    if (isRemote) return false;
    final _storagePath = storagePath;
    return _storagePath != null && !File(_storagePath).existsSync();
  }

  // providers
  // cloud entries are never local vault or media store content

  bool get _isVaultContent => false;

  bool get _isMediaStoreContent => false;

  bool get isMediaStoreMediaContent => false;

  // edition

  bool get canEdit => !settings.isReadOnly && path != null && !trashed && (_isMediaStoreContent || _isVaultContent);

  bool get canEditDate => canEdit && (isExifEditionSupported || isXmpEditionSupported);

  bool get canEditLocation => canEdit && (isExifEditionSupported || mimeType == MimeTypes.mp4);

  bool get canEditTitleDescription => canEdit && isXmpEditionSupported;

  bool get canEditRating => canEdit && isXmpEditionSupported;

  bool get canEditTags => canEdit && isXmpEditionSupported;

  bool get canRotate => canEdit && (isExifEditionSupported || mimeType == MimeTypes.mp4);

  bool get canFlip => canEdit && isExifEditionSupported;

  // app support

  bool get isDecodingSupported => isRemote ? AppSupport.canDecodeRemote(mimeType) : AppSupport.canDecode(mimeType);

  bool get isExifEditionSupported => AppSupport.canEditExif(mimeType);

  bool get isIptcEditionSupported => AppSupport.canEditIptc(mimeType);

  bool get isXmpEditionSupported => AppSupport.canEditXmp(mimeType);

  bool get isMetadataRemovalSupported => AppSupport.canRemoveMetadata(mimeType);
}
