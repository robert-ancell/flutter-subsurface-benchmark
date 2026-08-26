// Minimal static app: draws one frame, then stays idle. Used to check that the
// last presented Flutter frame actually reaches the screen (a synchronized
// Wayland subsurface only becomes visible when its parent surface commits).

import 'package:flutter/material.dart';

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ColoredBox(
        color: Color(0xFFFF0000),
        child: Center(
          child: Text(
            'STATIC',
            textDirection: TextDirection.ltr,
            style: TextStyle(fontSize: 96, color: Color(0xFFFFFFFF)),
          ),
        ),
      ),
    ),
  );
}
