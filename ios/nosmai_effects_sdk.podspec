Pod::Spec.new do |s|
  s.name             = 'nosmai_effects_sdk'
  s.version          = '2.0.3-beta.1'
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
  s.source           = { :git => 'https://github.com/nosmai/nosmai_effects_sdk_flutter.git', :tag => "v#{s.version}" }
  s.dependency 'Flutter'
  native_version = '3.0.8-beta.1'
  # A leftover development framework must not shadow the pinned native SDK.
  local_info = File.expand_path('Framework/nosmai.framework/Info.plist', __dir__)
  if File.file?(local_info)
    require 'cfpropertylist'
    plist = CFPropertyList::List.new(:file => local_info)
    local_version = CFPropertyList.native_types(plist.value)['CFBundleShortVersionString']
  end
  if local_version == native_version
    s.vendored_frameworks = 'Framework/nosmai.framework'
  else
    s.dependency 'NosmaiCameraSDK', native_version
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
