import 'dart:io';
import 'dart:math';

import 'package:purer/model/entry/entry.dart';
import 'package:purer/model/entry/extensions/props.dart';
import 'package:purer/theme/icons.dart';
import 'package:purer/theme/themes.dart';
import 'package:purer/utils/mime_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

class const ErrorThumbnail({
  super.key,
  required final PurerEntry entry,
  required final double extent,
}) extends StatefulWidget {
  @override
  State<ErrorThumbnail> createState() => _ErrorThumbnailState();
}

class _ErrorThumbnailState extends State<ErrorThumbnail> {
  late Future<bool> _exists;

  PurerEntry get entry => widget.entry;

  double get extent => widget.extent;

  @override
  void initState() {
    super.initState();
    final path = entry.storagePath;
    _exists = path != null ? File(path).exists() : SynchronousFuture(true);
  }

  @override
  Widget build(BuildContext context) {
    final color = Themes.backgroundTextColor(context);
    return FutureBuilder<bool>(
      future: _exists,
      builder: (context, snapshot) {
        Widget child;
        if (snapshot.connectionState != ConnectionState.done) {
          child = const SizedBox();
        } else {
          final exists = snapshot.data!;
          child = exists
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    final fontSize = min(extent, constraints.biggest.width) / 5;
                    return Text(
                      MimeUtils.displayType(entry.mimeType),
                      style: TextStyle(
                        color: color,
                        fontSize: fontSize,
                      ),
                      textAlign: .center,
                    );
                  },
                )
              : Icon(
                  AIcons.broken,
                  size: extent / 2,
                  color: color,
                );
        }
        return Container(
          alignment: .center,
          color: Themes.firstLayerColor(context),
          width: extent,
          height: extent,
          child: child,
        );
      },
    );
  }
}
