Pod::Spec.new do |s|
  s.name         = "NativePhotosUI"
  s.version      = "1.0.0"
  s.summary      = "Local PhotosUI Turbo Module"
  s.homepage     = "https://github.com"
  s.license      = "MIT"
  s.author       = "Developer"
  s.platforms    = { :ios => "16.0" }
  s.source       = { :git => "" }

  s.source_files = "**/*.{h,m,mm,swift}"
  s.swift_version = "5.0"

  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++17",
    "CLANG_CXX_LIBRARY" => "libc++",
    "OTHER_CPLUSPLUSFLAGS" => "$(inherited) -DFOLLY_NO_CONFIG -DFOLLY_MOBILE=1 -DFOLLY_USE_LIBCPP=1",
    "HEADER_SEARCH_PATHS" => "\"$(PODS_TARGET_SRCROOT)/React\" \"$(PODS_ROOT)/Headers/Private/React-Core\""
  }

  install_modules_dependencies(s)
end
