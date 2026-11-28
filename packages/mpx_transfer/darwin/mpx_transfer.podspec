Pod::Spec.new do |s|
  s.name             = 'mpx_transfer'
  s.version          = '0.0.1'
  s.summary          = 'Native side of mpx_transfer.'
  s.description      = 'Native side of mpx_transfer: the OS envelope that keeps system transfers running.'
  s.homepage         = 'https://github.com/itsezlife/mpx'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'mpx' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  # The same sources the Swift package builds.
  s.source_files     = 'mpx_transfer/Sources/mpx_transfer/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  # iOS 15 is the set's floor (spec, minimum versions).
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '10.15'
  s.ios.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.osx.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
