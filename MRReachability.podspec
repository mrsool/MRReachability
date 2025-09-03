Pod::Spec.new do |s|
s.name         = "MRReachability"
s.version = "1.0.0"
s.ios.frameworks = ["Network", "SystemConfiguration", "UIKit"]
s.summary      = "NWPathMonitor-backed reachability with a legacy-style API."
s.description  = <<-DESC
MRReachability wraps Apple's NWPathMonitor to provide a simple 3-state
(wifi/cellular/unavailable) API with legacy-style callbacks & notifications.
DESC

s.homepage     = "https://github.com/mrsool/MRReachability"
s.license      = { :type => "MIT", :file => "LICENSE" }
s.author       = { "Uvais Khan" => "rao.khan@mrsool.co" }

# IMPORTANT: iOS only for now to avoid cross-platform build failures
s.platform     = :ios, "12.0"

s.source       = { :git => "https://github.com/UvaisRao/MRReachability.git",
:tag => "v#{s.version}" }

s.swift_versions = ["5.7", "5.8", "5.9", "6.0"]

s.source_files = "Sources/MRReachability/**/*.swift"

# Link iOS frameworks only
s.ios.frameworks = ["Network", "SystemConfiguration", "UIKit"]
end
