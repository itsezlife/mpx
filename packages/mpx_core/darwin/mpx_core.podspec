Pod::Spec.new do |s|
  s.name             = 'mpx_core'
  s.version          = '0.0.1'
  s.summary          = 'Native side of mpx_core: the frame texture host.'
  s.description      = 'The iOS and macOS frame texture host of mpx_core: a FlutterTexture per texture over a ring of IOSurface-backed CVPixelBuffers, with the C lock and post entry points render workers call through FFI.'
  s.homepage         = 'https://github.com/itsezlife/mpx'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'mpx' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/MpxCorePlugin.h'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  # iOS 15 and macOS 12 are the set's floor (spec, minimum versions).
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.frameworks = 'CoreVideo'
  s.requires_arc = true
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
