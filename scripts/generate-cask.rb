#!/usr/bin/env ruby
require "digest"
require "fileutils"

repository, archive, output, version = ARGV
abort "Usage: ruby scripts/generate-cask.rb owner/repo archive.zip output.rb VERSION" unless version
abort "Invalid repository" unless repository.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
abort "Invalid version" unless version.match?(/\A\d+\.\d+\.\d+\z/)
abort "Archive missing" unless File.file?(archive)
template = File.read(File.expand_path("../Packaging/stoneaxe.rb.in", __dir__))
cask = template.sub(/^# Release template:.*\n/, "")
               .gsub("REPOSITORY", repository)
               .gsub("SHA256", Digest::SHA256.file(archive).hexdigest)
               .sub('version "0.1.0"', "version \"#{version}\"")
FileUtils.mkdir_p(File.dirname(output))
File.write(output, cask)
puts "Generated #{output} with the archive's SHA-256 checksum."
