#!/usr/bin/env ruby
# frozen_string_literal: true

# Render config/systemd/scanner-worker.service for the image (#1209): substitute the
# image's real ruby bin dir for @RUBY_BIN_DIR@. Fails loud rather than ship a unit with
# a blank PATH entry or an unsubstituted placeholder (a silent no-op edit).
#   usage: render-unit.rb TEMPLATE DEST RUBY_BIN_DIR
PLACEHOLDER = '@RUBY_BIN_DIR@'

template, dest, ruby_bin = ARGV
abort 'usage: render-unit.rb TEMPLATE DEST RUBY_BIN_DIR' if [template, dest].any?(&:nil?)
abort 'render-unit: ruby bin dir is blank (is ruby on PATH at bake time?)' if ruby_bin.to_s.strip.empty?

text = File.read(template)
abort "render-unit: #{template} has no #{PLACEHOLDER} placeholder to substitute" unless text.include?(PLACEHOLDER)

File.write(dest, text.gsub(PLACEHOLDER, ruby_bin))
