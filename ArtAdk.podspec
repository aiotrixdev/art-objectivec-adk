Pod::Spec.new do |spec|
  spec.name         = "ArtAdk"
  spec.version      = "1.0.3"
  spec.summary      = "Objective-C ADK for ART - A Realtime Tech Communication."
  spec.description  = <<-DESC
                    Objective-C ADK for ART, a realtime messaging platform providing WebSocket-based channels,
                    presence tracking, end-to-end encrypted messaging, CRDT-backed shared objects,
                    AI agents and orchestrators, file storage and notifications.
                    DESC

  spec.homepage     = "https://arealtimetech.com/"
  spec.license      = { :type => "MIT", :file => "LICENSE" }
  spec.author       = { "AIOTRIX DEVELOPERS" => "aiotrix.dev@gmail.com" }
  spec.source       = { :git => "https://github.com/aiotrixdev/art-objectivec-adk.git", :tag => spec.version.to_s }

  spec.ios.deployment_target = "15.0"
  spec.osx.deployment_target = "12.0"

  # `pod 'ArtAdk'` installs the core SDK. Add `pod 'ArtAdk/Notifications'`
  # for the optional notifications add-on.
  spec.default_subspecs = "Core"

  # Each class's header and implementation sit together in
  # Sources/ArtAdk/include/ArtAdk/<Folder>/. Every folder is searchable, so
  # sources can use quoted imports.
  spec.pod_target_xcconfig = {
    'GCC_C_LANGUAGE_STANDARD' => 'gnu17',
    # `@import ArtAdk;` also works when the pod is built as a static library.
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => [
      '$(inherited)',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdk/include/ArtAdk/Agentic"',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdk/include/ArtAdk/Auth"',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdk/include/ArtAdk/Config"',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdk/include/ArtAdk/CRDT"',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdk/include/ArtAdk/Crypto"',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdk/include/ArtAdk/Crypto/TweetNaCl"',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdk/include/ArtAdk/Storage"',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdk/include/ArtAdk/Types"',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdk/include/ArtAdk/Util"',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdk/include/ArtAdk/WebSocket"',
      '"${PODS_TARGET_SRCROOT}/Sources/ArtAdkNotifications/include/ArtAdkNotifications"'
    ].join(' ')
  }

  spec.subspec "Core" do |core|
    core.source_files         = "Sources/ArtAdk/**/*.{h,m,c}"
    core.public_header_files  = "Sources/ArtAdk/include/ArtAdk/**/*.h"
    # Internal headers: used by the ADK's own sources, not installed for apps.
    core.project_header_files = "Sources/ArtAdk/include/ArtAdk/Agentic/ARTThreadStateStore.h",
                                "Sources/ArtAdk/include/ArtAdk/Crypto/TweetNaCl/ctweetnacl.h",
                                "Sources/ArtAdk/include/ArtAdk/WebSocket/ARTEventBuffer.h",
                                "Sources/ArtAdk/include/ArtAdk/WebSocket/BaseSubscription+Internal.h"
    core.header_mappings_dir  = "Sources/ArtAdk/include/ArtAdk"
    core.frameworks           = "UniformTypeIdentifiers"
  end

  spec.subspec "Notifications" do |notifications|
    notifications.dependency "ArtAdk/Core"
    notifications.source_files        = "Sources/ArtAdkNotifications/**/*.{h,m}"
    notifications.public_header_files = "Sources/ArtAdkNotifications/include/ArtAdkNotifications/*.h"
    notifications.header_mappings_dir = "Sources/ArtAdkNotifications/include/ArtAdkNotifications"
  end
end
