# Reverse-direction oracle: reads cookies produced by the CRYSTAL port
# through the ORIGINAL actionpack 8.1.4 cookie jars.
#
#   ruby oracle/verify_cookies.rb <file.tsv>
#
# Input lines: "<name>\t<jar>\t<expected_json>\t<wire_value>"
#   name       — cookie name
#   jar        — "signed" or "encrypted"
#   expected_json — JSON dump of the value the Crystal side stored
#   wire_value — raw (unescaped) cookie value written by the port
# Output: "<line_no>\tOK" or "<line_no>\tFAIL <detail>" (exit 1 on any FAIL).
# The Crystal spec (spec/cookies_oracle_spec.cr) shells out to this script.

gem "actionpack", "= 8.1.4"
require "action_dispatch"
require "active_support/key_generator"
require "active_support/message_encryptor"
require "active_support/messages/rotation_configuration"
require "action_dispatch/middleware/cookies"
require "rack"

SECRET = "b3c641c1e9d1e0e4a1e1c6e8e5b7d2f4a9c0d3e6f1a2b4c5d6e7f8a9b0c1d2e3f"

def env(cookie_header)
  {
    "action_dispatch.secret_key_base" => SECRET,
    "action_dispatch.key_generator" => ActiveSupport::CachingKeyGenerator.new(
      ActiveSupport::KeyGenerator.new(SECRET, iterations: 1000)),
    "action_dispatch.signed_cookie_salt" => "signed cookie",
    "action_dispatch.authenticated_encrypted_cookie_salt" => "authenticated encrypted cookie",
    "action_dispatch.use_authenticated_cookie_encryption" => true,
    "action_dispatch.cookies_serializer" => :json,
    "action_dispatch.use_cookies_with_metadata" => true,
    "action_dispatch.cookies_rotations" => ActiveSupport::Messages::RotationConfiguration.new,
    "action_dispatch.cookies_same_site_protection" => nil,
    "HTTP_COOKIE" => cookie_header,
    "REQUEST_METHOD" => "GET", "PATH_INFO" => "/", "HTTP_HOST" => "example.com",
  }
end

path = ARGV[0] or abort "usage: verify_cookies.rb <file.tsv>"
failed = 0
File.readlines(path).each_with_index do |line, i|
  line = line.chomp
  next if line.empty?
  name, jar, expected_json, wire = line.split("\t", 4)
  header = "#{name}=#{Rack::Utils.escape(wire)}"
  cookie_jar = ActionDispatch::Request.new(env(header)).cookie_jar
  actual =
    case jar
    when "signed"    then cookie_jar.signed[name.to_sym]
    when "encrypted" then cookie_jar.encrypted[name.to_sym]
    end
  actual_json = JSON.generate(actual)
  if actual_json == expected_json
    puts "#{i + 1}\tOK"
  else
    failed += 1
    puts "#{i + 1}\tFAIL expected=#{expected_json} got=#{actual_json}"
  end
end
abort "FAILURES: #{failed}" if failed > 0
