import 'package:purer/model/entry/entry.dart';
import 'package:purer_video/purer_video.dart';
import 'package:material_ui/material_ui.dart';

class VideoView extends StatefulWidget {
  final PurerEntry entry;
  final PurerVideoController controller;

  const new({
    super.key,
    required this.entry,
    required this.controller,
  });

  @override
  State<StatefulWidget> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> {
  PurerEntry get entry => widget.entry;

  PurerVideoController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _registerWidget(widget);
  }

  @override
  void didUpdateWidget(covariant VideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _unregisterWidget(oldWidget);
    _registerWidget(widget);
  }

  @override
  void dispose() {
    _unregisterWidget(widget);
    super.dispose();
  }

  void _registerWidget(VideoView widget) {
    widget.controller.playCompletedListenable.addListener(_onPlayCompleted);
  }

  void _unregisterWidget(VideoView widget) {
    widget.controller.playCompletedListenable.removeListener(_onPlayCompleted);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackStatus>(
      stream: controller.statusStream,
      builder: (context, _) {
        return controller.isReady ? controller.buildPlayerWidget(context) : const SizedBox();
      },
    );
  }

  // not called when looping
  void _onPlayCompleted() => controller.seekTo(0);
}
