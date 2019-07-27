#
# Be sure to run `pod lib lint ZippyJSONCFamily.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'ZippyJSONCFamily'
  s.version          = '0.1.0'
  s.summary          = 'A short description of ZippyJSONCFamily.'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
TODO: Add long description of the pod here.
                       DESC

  s.homepage         = 'https://github.com/michaeleisel/ZippyJSONCFamily'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'michaeleisel' => 'michael.eisel@gmail.com' }
  s.source           = { :git => 'https://github.com/michaeleisel/ZippyJSONCFamily.git', :tag => s.version.to_s }

  s.ios.deployment_target = '10.0'
  s.osx.deployment_target = '10.12'
  s.library = 'c++'

  s.source_files = 'Sources/**/*.{h,hh,mm,m,c,cpp,swift}'
  s.public_header_files = 'Sources/**/*.h'
  s.private_header_files = ['Sources/ZippyJSONCFamily/*.h', 'Sources/ZippyJSONCFamily/rapidjson/**/*.h']
end
