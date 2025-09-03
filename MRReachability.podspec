Pod::Spec.new do |s|
  s.name         = 'MRReachability'
  s.version      = '1.0.0'
  s.summary      = 'Modern reachability wrapper using NWPathMonitor.'
  s.description  = <<-DESC
    MRReachability is a lightweight, NWPathMonitor-based reachability utility
    offering a legacy-compatible API while using modern Network.framework under the hood.
  DESC
  s.homepage     = 'https://github.com/mrsool/MRReachability'
  s.license      = { :type => 'MIT', :file => 'LICENSE' }
  s.author       = { 'Rao Uvais' => 'rao.khan@mrsool.co' }
  s.source       = { :git => 'https://github.com/mrsool/MRReachability.git', :tag => s.version }

  s.ios.deployment_target = '13.0'
  s.swift_version = '5.0'

  # Adjust paths to match your repo layout
  s.source_files = 'Sources/**/*.{swift}'
  s.frameworks   = 'Network', 'SystemConfiguration'
end
