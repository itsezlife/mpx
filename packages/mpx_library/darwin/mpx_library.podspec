Pod::Spec.new do |s|
  s.name             = 'mpx_library'
  s.version          = '0.0.1'
  s.summary          = 'Native side of mpx_library.'
  s.description      = 'Native side of mpx_library: the device media library and the file intake.'
  s.homepage         = 'https://github.com/itsezlife/mpx'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'mpx' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.ios.dependency 'Flutter'
  # iOS 15 is the set's floor (spec, minimum versions).
  s.ios.deployment_target = '15.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'
end
