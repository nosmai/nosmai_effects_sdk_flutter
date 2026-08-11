# ProGuard rules for the Nosmai Effects SDK Flutter plugin
# These rules will be applied to consumer apps using this plugin

# Keep all classes in the Nosmai effect internal package
-keep class com.nosmai.effect.internal.** { *; }
-keepclassmembers class com.nosmai.effect.internal.** { *; }

# Keep the specific Nosmai class and all its methods (especially getResource_path)
-keep class com.nosmai.effect.internal.Nosmai {
    public static java.lang.String getResource_path();
    *;
}

# Keep NosmaiFilter class and all its methods
-keep class com.nosmai.effect.internal.NosmaiFilter { *; }

# Keep all classes that might be accessed via JNI
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep classes accessed via reflection in the plugin
-keep class com.nosmai.nosmai_flutter.** { *; }

# Keep Camera2Helper and its methods
-keep class com.nosmai.nosmai_flutter.Camera2Helper { *; }

# Keep the plugin main class
-keep class com.nosmai.nosmai_flutter.NosmaiFlutterPlugin { *; }

# Keep exceptions for better error reporting
-keepattributes Exceptions

# Keep annotations
-keepattributes *Annotation*

# If the Nosmai SDK uses any specific annotations, keep them
-keep @interface com.nosmai.** { *; }

# Prevent obfuscation of classes that might be serialized
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}
