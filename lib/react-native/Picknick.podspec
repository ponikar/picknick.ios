require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "Picknick"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "18.0" }
  s.source       = { :git => "https://github.com/ponikar/picknick.ios.git", :tag => "#{s.version}" }
  s.source_files = ["ios/**/*.swift"]

  load "nitrogen/generated/ios/Picknick+autolinking.rb"
  add_nitrogen_files(s)

  spm_dependency(s,
    url: "https://github.com/ponikar/picknick.ios.git",
    requirement: { kind: "branch", branch: "main" },
    products: %w[PicknickCore PicknickStore PicknickPhotos PicknickIndexer PicknickCLIP PicknickVision PicknickPlaces PicknickSearch]
  )

  s.dependency "React-jsi"
  s.dependency "React-callinvoker"
  install_modules_dependencies(s)
end
