Pod::Spec.new do |spec|
  spec.name = 'ViewScopeServer'
  spec.version = '1.2.2'
  spec.summary = 'AppKit / UIKit UI inspection bridge for the ViewScope macOS client.'
  spec.description = 'Embed ViewScopeServer into a debug build to inspect native macOS and iOS windows, views and layers from ViewScope.'
  spec.homepage = 'https://github.com/wangwanjie/ViewScope'
  spec.license = { :type => 'MIT', :file => '../LICENSE' }
  spec.author = { 'VanJay' => 'vanjay.dev@gmail.com' }
  spec.source = { :git => 'https://github.com/wangwanjie/ViewScope.git', :tag => "v#{spec.version}" }
  spec.osx.deployment_target = '11.0'
  spec.ios.deployment_target = '13.0'
  spec.swift_version = '6.0'
  spec.requires_arc = true
  spec.source_files = 'Sources/ViewScopeServer/**/*.swift', 'Sources/ViewScopeServerBootstrap/*.{h,m}'
  spec.public_header_files = 'Sources/ViewScopeServerBootstrap/*.h'
  spec.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -Wl,-u,_ViewScopeServerBootstrapAnchor'
  }
  spec.frameworks = 'Foundation', 'Network', 'QuartzCore', 'CoreGraphics'
  spec.osx.frameworks = 'AppKit'
  spec.ios.frameworks = 'UIKit'
end
