# Reverse-verification for the OpenAPI document (Iteration 10):
# validates the JSON written by the Crystal spec against the real
# openapi3_parser gem (0.10.1, OpenAPI 3.0 specification).
#
# Usage: GEM_PATH=~/.gem/ruby/3.4.0 ruby oracle/verify_openapi.rb <doc.json>
# Prints "OK" (exit 0) or the error list (exit 1).
gem "openapi3_parser", "= 0.10.1"
require "openapi3_parser"

path = ARGV[0] or abort "usage: verify_openapi.rb <doc.json>"
doc = Openapi3Parser.load_file(path)
unless doc.valid?
  doc.errors.each { |e| puts e.message }
  exit 1
end
puts "OK"
