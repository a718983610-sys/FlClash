/// Build-time switches for features whose code stays either way, each
/// defaulting to how it ships. A disabled feature with a setting hides it and
/// ignores the stored value, so switching it back on restores what the user
/// had chosen.
class Feature {
  const Feature({
    this.sidebarBlur = const bool.fromEnvironment('FEATURE_SIDEBAR_BLUR'),
    this.bootSkeleton = const bool.fromEnvironment('FEATURE_BOOT_SKELETON'),
    this.glassFrostBoost = const bool.fromEnvironment(
      'FEATURE_GLASS_FROST_BOOST',
    ),
  });

  final bool sidebarBlur;

  /// Paints the static boot skeleton as the first frame and swaps the real
  /// app in when the startup chain lands. Off until a real device has
  /// measured the TTID it exists to cut (testbed A).
  final bool bootSkeleton;

  /// Captures glass at frost 1.5 instead of 2, shrinking the regular
  /// panes' capture area. Off until a real device has confirmed text
  /// under glass stays readable at the coarser capture (testbed B).
  final bool glassFrostBoost;
}

Feature feature = const Feature();
