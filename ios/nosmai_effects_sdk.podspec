Pod::Spec.new do |s|
  s.name             = 'nosmai_effects_sdk'
  s.version          = '1.0.1'
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
  s.dependency 'NosmaiCameraSDK', '~> 3.0.3'
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
