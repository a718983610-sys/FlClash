/// Build-time switches for features whose code stays either way, each
/// defaulting to how it ships. A disabled feature with a setting hides it and
/// ignores the stored value, so switching it back on restores what the user
/// had chosen.
class Feature {
  const Feature({
    this.sidebarBlur = const bool.fromEnvironment('FEATURE_SIDEBAR_BLUR'),
    this.bootSkeleton = const bool.fromEnvironment('FEATURE_BOOT_SKELETON'),
  });

  final bool sidebarBlur;

  /// Paints the static boot skeleton as the first frame and swaps the real
  /// app in when the startup chain lands. Off until a real device has
  /// measured the TTID it exists to cut (testbed A).
  final bool bootSkeleton;
}

Feature feature = const Feature();
