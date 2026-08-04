#!/usr/bin/env ruby
# Patches the Xcode project to include iOS native Swift plugin files.
# Run from within the ios/ directory.

require 'xcodeproj'

SWIFT_FILES = %w[
  ContinuousCameraPlugin.swift
  LanBackupPlugin.swift
  VideoExportPlugin.swift
  RecordingThumbnailPlugin.swift
  VideoWatermarkPlugin.swift
  OrderInfoReceiverPlugin.swift
].freeze

project_path = 'Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.select { |t| t.name == 'Runner' }.first
raise "Runner target not found" unless target

runner_group = project.main_group['Runner'] || project.main_group.new_group('Runner')

SWIFT_FILES.each do |filename|
  file_path = "Runner/#{filename}"
  full_path = File.join(__dir__, '..', file_path)

  unless File.exist?(full_path)
    puts "Warning: #{full_path} not found, skipping."
    next
  end

  # Skip if already in target
  next if target.source_build_phase.files.any? { |f| f.file_ref&.path == filename }

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
puts "Project saved successfully."
