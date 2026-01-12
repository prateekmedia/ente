import 'dart:io';

import 'package:ente_ui/pages/log_file_viewer.dart' as ente_ui;
import 'package:flutter/material.dart';

class LogFileViewer extends StatelessWidget {
  final File file;

  const LogFileViewer(this.file, {super.key});

  @override
  Widget build(BuildContext context) {
    return ente_ui.LogFileViewer(file);
  }
}
