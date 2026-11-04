import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Content paints behind the system bars; only their glyph contrast changes.
SystemUiOverlayStyle systemBarsFor(Brightness background) =>
    (background == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark)
        .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarContrastEnforced: false,
        );
