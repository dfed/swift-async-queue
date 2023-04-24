Pod::Spec.new do |s|
  s.name     = 'AsyncQueue'
  s.version  = '0.4.0'
  s.license  = 'MIT'
  s.summary  = 'A queue that enables ordered sending of events from synchronous to asynchronous code.'
  s.homepage = 'https://github.com/dfed/swift-async-queue'
  s.authors  = 'Dan Federman'
  s.source   = { :git => 'https://github.com/dfed/swift-async-queue.git', :tag => s.version }
  s.swift_version = '5.8'
  s.source_files = 'Sources/**/*.{swift}'
  s.ios.deployment_target = '13.0'
  s.tvos.deployment_target = '13.0'
  s.watchos.deployment_target = '6.0'
  s.macos.deployment_target = '10.15'
end
