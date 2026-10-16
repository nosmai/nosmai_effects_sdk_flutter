Pod::Spec.new do |s|
  s.name             = 'nosmai_effects_sdk'
  s.version          = '2.0.2'
  s.summary          = 'Official Flutter plugin for Nosmai real-time AR, beauty effects, and camera games.'
  s.description      = <<-DESC
    Nosmai Effects SDK applies real-time AR effects, beauty filters, backgrounds,
    interactive camera games, and visual enhancements to live camera frames on
    supported iOS devices.

    To use the SDK, developers must register a project through Nosmai Console and obtain a unique API key.
    The API key is used to initialize the camera view and enable filtering capabilities.
  DESC
  s.homepage         = 'https://nosmai.com/docs/effects/platforms/flutter/'
  s.license          = { :type => 'Commercial', :file => '../LICENSE' }
  s.author           = { 'Nosmai' => 'admin@nosmai.com' }
  s.source           = { :git => 'https://github.com/nosmai/nosmai_effects_sdk_flutter.git', :tag => s.version.to_s }
  s.dependency 'Flutter'
  # Local native-SDK validation: use an ignored framework copied into
  # ios/Framework. Published packages do not contain this directory and
  # therefore continue to resolve the production CocoaPod dependency.
  local_framework = File.expand_path('Framework/nosmai.framework', __dir__)
  if File.exist?(local_framework)
    s.vendored_frameworks = 'Framework/nosmai.framework'
  else
    s.dependency 'NosmaiCameraSDK', '3.0.7'
  end
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.resource_bundles = {
    'nosmai_effects_sdk_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }

  s.platform = :ios, '15.0'

  # Required frameworks
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'OpenGLES', 'QuartzCore', 'UIKit', 'Foundation'

  # Pod target configuration
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '$(inherited) -framework nosmai'
  }

  # Additional compiler flags if needed
  s.compiler_flags = '-Dnosmai_effects_sdk_PLUGIN=1'
end
