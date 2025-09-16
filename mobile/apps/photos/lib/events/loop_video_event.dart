import "package:photos/events/event.dart";

class LoopVideoEvent extends Event {
  final bool shouldLoop;

  LoopVideoEvent(this.shouldLoop);
}