# ProGuard and R8 rules for the Nosmai Effects Flutter plugin, applied to consumer apps.
# The native Nosmai SDK ships its own consumer rules for its public API and JNI entry
# points, so only the classes below need to be kept here.

# Flutter plugin classes. Flutter registers them, and native code calls back into them.
-keep class com.nosmai.nosmai_flutter.** { *; }

# Internal SDK class that the native library looks up by name. Native SDK 3.0.7 does
# not keep it in its own consumer rules.
-keep class com.nosmai.effect.internal.NosmaiFilter$ParameterInfo { *; }

# Keep declared exceptions for clearer error reporting.
-keepattributes Exceptions
