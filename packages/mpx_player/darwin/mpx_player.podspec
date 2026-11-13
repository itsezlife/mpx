Pod::Spec.new do |s|
  s.name             = 'mpx_player'
  s.version          = '0.0.1'
  s.summary          = 'AVPlayer backend of mpx_player.'
  s.description      = 'AVPlayer drawing into Flutter textures, reading bytes through the http_bytes_cache native reader.'
  s.homepage         = 'https://github.com/itsezlife/mpx'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'mpx' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.frameworks       = 'AVFoundation', 'CoreVideo', 'QuartzCore'
  # iOS 15 and macOS 12 are the set's floor (spec, minimum versions).
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'
end
