Pod::Spec.new do |spec|
  spec.name = 'ViewScopeServer'
  spec.version = '1.2.1'
  spec.summary = 'AppKit UI inspection bridge for the ViewScope macOS client.'
  spec.description = 'Embed ViewScopeServer into a debug build to inspect native macOS windows and views from ViewScope.'
  spec.homepage = 'https://github.com/wangwanjie/ViewScope'
  spec.license = { :type => 'MIT', :file => '../LICENSE' }
  spec.author = { 'VanJay' => 'vanjay.dev@gmail.com' }
  spec.source = { :git => 'https://github.com/wangwanjie/ViewScope.git', :tag => "v#{spec.version}" }
  spec.osx.deployment_target = '11.0'
  spec.swift_version = '6.0'
  spec.requires_arc = true
  spec.source_files = 'Sources/ViewScopeServer/**/*.swift', 'Sources/ViewScopeServerBootstrap/*.{h,m}'
  spec.public_header_files = 'Sources/ViewScopeServerBootstrap/*.h'
  spec.frameworks = 'AppKit', 'Foundation', 'Network'
end
