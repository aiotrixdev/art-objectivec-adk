Pod::Spec.new do |spec|
  spec.name         = "ArtAdk"
  spec.version      = "1.0.1" 
  spec.summary      = "Objective-C ADK for ART - A Realtime Tech Communication."  
  spec.description  = <<-DESC
                    Objective-C ADK for ART, a realtime messaging platform providing WebSocket-based channels, 
                    presence tracking, end-to-end encrypted messaging, and CRDT-backed shared objects.
                    DESC

  spec.homepage     = "https://arealtimetech.com/"
  spec.license      = { :type => "MIT", :file => "LICENSE" }
  spec.author       = { "AIOTRIX DEVELOPERS" => "aiotrix.dev@gmail.com" }
  
  spec.source       = { :git => "https://github.com/aiotrixdev/art-objectivec-adk.git", :tag => spec.version.to_s }

  # 1. Platforms (Mapped from .iOS(.v15) and .macOS(.v10_15))
  spec.ios.deployment_target = "15.0"
  spec.osx.deployment_target = "10.15"

  # 2. Source and Headers (Mapped from path: "Sources/ADK" and publicHeadersPath: "include")
  # This grabs all Objective-C and C files inside your ADK folder
  spec.source_files  = "Sources/ADK/**/*.{h,m,c,mm,cpp}"
  spec.public_header_files = "Sources/ADK/**/*.h"
  spec.header_mappings_dir = "Sources/ADK"

  # 3. Build Settings (Mapped from cSettings and cLanguageStandard)
  spec.pod_target_xcconfig = {
    'GCC_C_LANGUAGE_STANDARD' => 'gnu17',
    'HEADER_SEARCH_PATHS' => [
      '$(inherited)',
      '"${PODS_TARGET_SRCROOT}/Sources/ADK/Agentic"',
      '"${PODS_TARGET_SRCROOT}/Sources/ADK/Auth"',
      '"${PODS_TARGET_SRCROOT}/Sources/ADK/Config"',
      '"${PODS_TARGET_SRCROOT}/Sources/ADK/CRDT"',
      '"${PODS_TARGET_SRCROOT}/Sources/ADK/Crypto"',
      '"${PODS_TARGET_SRCROOT}/Sources/ADK/Crypto/TweetNaCl"',
      '"${PODS_TARGET_SRCROOT}/Sources/ADK/Types"',
      '"${PODS_TARGET_SRCROOT}/Sources/ADK/WebSocket"'
    ].join(' ')
  }
end