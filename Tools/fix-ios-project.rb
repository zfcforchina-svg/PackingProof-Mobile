#!/usr/bin/env ruby
# Patches the Xcode project to include iOS native Swift plugin files.
# Run from the Flutter project root directory.

require 'xcodeproj'

SWIFT_FILES = %w[
  ContinuousCameraPlugin.swift
  LanBackupPlugin.swift
  VideoExportPlugin.swift
  RecordingThumbnailPlugin.swift
  VideoWatermarkPlugin.swift
  OrderInfoReceiverPlugin.swift
  PackingProofPlugin.swift
].freeze

project_path = 'ios/Runner.xcodeproj'
runner_dir = 'ios/Runner'

unless File.exist?(project_path)
  puts "Error: #{project_path} not found. Run from project root."
  exit 1
end

project = Xcodeproj::Project.open(project_path)
target = project.targets.select { |t| t.name == 'Runner' }.first
raise "Runner target not found in Xcode project" unless target

runner_group = project.main_group['Runner'] ||
               project.main_group.groups.find { |g| g.name == 'Runner' || g.path == 'Runner' }

unless runner_group
  puts "Warning: Runner group not found, creating..."
  runner_group = project.main_group.new_group('Runner', runner_dir)
end

SWIFT_FILES.each do |filename|
  file_path = "Runner/#{filename}"
  full_path = File.join(runner_dir, filename)

  unless File.exist?(full_path)
    puts "Warning: #{full_path} not found, skipping."
    next
  end

  # Skip if already in target
  if target.source_build_phase.files.any? { |f| f.file_ref&.path == filename }
    puts "Skipping #{filename} (already in target)"
    next
  end

  file_ref = runner_group.new_file(file_path)
  target.source_build_phase.add_file_reference(file_ref)
  puts "Added #{filename} to Runner target"
end

# Ensure Swift version and deployment target
target.build_configurations.each do |config|
  config.build_settings['SWIFT_VERSION'] ||= '5.0'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] ||= '15.0'
end

project.save
puts "Xcode project saved successfully."
