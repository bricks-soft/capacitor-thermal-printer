require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
Pod::Spec.new do |s|
  s.name = 'BricksSoftCapacitorThermalPrinter'
  s.version = package['version']
  s.summary = package['description']
  s.license = package['license']
  s.homepage = package['homepage']
  s.author = package['author']
  s.source = { :git => 'https://github.com/bricks-soft/capacitor-thermal-printer.git', :tag => 'v' + s.version.to_s }
  s.source_files = 'ios/Sources/ThermalPrinter/**/*.swift'
  s.ios.deployment_target = '15.0'
  s.module_name = 'ThermalPrinter'
  s.swift_version = '5.9'
  s.frameworks = 'CoreBluetooth', 'CoreImage', 'ImageIO', 'Network'
  s.dependency 'Capacitor', '>= 8.0.0', '< 9.0'
end
