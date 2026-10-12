# Synthetic oracle cases for ActionDispatch::Cookies (signed / encrypted /
# permanent cookie jars + Set-Cookie write options), captured from the
# ORIGINAL actionpack 8.1.4.
#
#   ruby oracle/cookies_cases.rb > oracle/cookies_expected.yml
#
# Each line: "<case_id>\t<rendered result>". Mirrored 1:1 in
# spec/cookies_oracle_spec.cr; the Crystal port must reproduce
# cookies_expected.yml exactly.
#
# The request env mirrors a Rails 8.1 app with config.load_defaults 8.1:
# cookies_serializer :json, use_cookies_with_metadata true,
# authenticated AES-256-GCM cookie encryption, KeyGenerator(iterations: 1000),
# gem-default salts ("signed cookie" / "authenticated encrypted cookie").
# cookies_same_site_protection is nil (a CRails deviation: the base jar does
# not inject a default SameSite attribute — railties territory).
#
# ck_encrypted_fixture_* carry a one-shot random-IV ciphertext baked into
# the yml as a fixture; the matching ck_encrypted_read_* lines hold what it
# must decrypt to.

gem "actionpack", "= 8.1.4"
require "action_dispatch"
require "active_support/key_generator"
require "active_support/message_encryptor"
require "active_support/messages/rotation_configuration"
require "action_dispatch/middleware/cookies"
require "rack"

SECRET = "b3c641c1e9d1e0e4a1e1c6e8e5b7d2f4a9c0d3e6f1a2b4c5d6e7f8a9b0c1d2e3f"

def env(extra = {})
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
    "REQUEST_METHOD" => "GET", "PATH_INFO" => "/", "HTTP_HOST" => "example.com",
  }.merge(extra)
end

# Runs the jar writes of one case and returns the (single) Set-Cookie line,
# or "" when the cookie was dropped (e.g. :secure over plain HTTP).
def set_cookie(extra = {})
  request = ActionDispatch::Request.new(env(extra))
  jar = request.cookie_jar
  yield jar
  response = Rack::Response.new
  jar.write(response)
  header = response.headers["Set-Cookie"]
  return "" if header.nil?
  Array(header).join("\n")
end

def read_cookie(header, name)
  request = ActionDispatch::Request.new(env("HTTP_COOKIE" => header))
  yield request.cookie_jar
end

def cookie_header(pair)
  key, value = pair
  "#{key}=#{Rack::Utils.escape(value)}"
end

# Extracts the (escaped) cookie value from a Set-Cookie line, undoing the
# escaping so the raw wire value can be replayed in a Cookie header.
def set_cookie_value(line)
  escaped = line[/=(.*?);/, 1] || line[/=(.*)\z/, 1]
  Rack::Utils.parse_cookies_header("k=#{escaped}")["k"]
end

def case_run(id)
  puts "#{id}\t#{yield.inspect}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

# --- plain jar + Set-Cookie options ---------------------------------

case_run("ck_plain_set") { set_cookie { |j| j[:user_name] = "david" } }
case_run("ck_plain_escape_set") { set_cookie { |j| j[:q] = "a+b/c=d e%f" } }
case_run("ck_opt_expires") {
  set_cookie { |j| j[:login] = { value: "XJ-122", expires: Time.utc(2030, 10, 15, 5, 0, 0) } }
}
case_run("ck_opt_httponly") { set_cookie { |j| j[:s] = { value: "v", httponly: true } } }
case_run("ck_opt_secure_http") { set_cookie { |j| j[:s] = { value: "v", secure: true } } }
case_run("ck_opt_secure_https") {
  set_cookie("HTTPS" => "on") { |j| j[:s] = { value: "v", secure: true } }
}
case_run("ck_opt_samesite_none") { set_cookie { |j| j[:s] = { value: "v", same_site: :none } } }
case_run("ck_opt_samesite_lax") { set_cookie { |j| j[:s] = { value: "v", same_site: :lax } } }
case_run("ck_opt_samesite_strict") { set_cookie { |j| j[:s] = { value: "v", same_site: :strict } } }
case_run("ck_opt_domain") { set_cookie { |j| j[:s] = { value: "v", domain: "example.com" } } }
case_run("ck_opt_path") { set_cookie { |j| j[:s] = { value: "v", path: "/app" } } }
case_run("ck_opt_combo") {
  set_cookie { |j| j[:c] = { value: "v", expires: Time.utc(2031, 1, 2, 3, 4, 5),
                             httponly: true, same_site: :strict, domain: "example.org" } }
}
case_run("ck_delete_plain") {
  set_cookie("HTTP_COOKIE" => "gone=1") { |j| j.delete(:gone) }
}
case_run("ck_delete_path") {
  set_cookie("HTTP_COOKIE" => "x=1") { |j| j.delete(:x, path: "/app") }
}

# --- signed jar (byte-exact, deterministic) --------------------------

case_run("ck_signed_int_set") { set_cookie { |j| j.signed[:user_id] = 123 } }
case_run("ck_signed_str_set") { set_cookie { |j| j.signed[:name] = "david" } }
case_run("ck_signed_expiring_set") {
  set_cookie { |j| j.signed[:login] = { value: "XJ-122", expires: Time.utc(2030, 10, 15, 5, 0, 0) } }
}

signed_user_id = set_cookie_value(set_cookie { |j| j.signed[:user_id] = 123 })
case_run("ck_signed_read_int") {
  read_cookie(cookie_header(["user_id", signed_user_id]), :user_id) { |j| j.signed[:user_id] }
}

signed_name = set_cookie_value(set_cookie { |j| j.signed[:name] = "david" })
case_run("ck_signed_read_str") {
  read_cookie(cookie_header(["name", signed_name]), :name) { |j| j.signed[:name] }
}
case_run("ck_signed_raw_read") {
  read_cookie(cookie_header(["name", signed_name]), :name) { |j| j[:name] }
}
case_run("ck_signed_tamper_read") {
  tampered = signed_name.dup
  tampered[0] = (tampered[0] == "A" ? "B" : "A")
  read_cookie(cookie_header(["name", tampered]), :name) { |j| j.signed[:name] }
}
case_run("ck_signed_purpose_mismatch") {
  # the value is signed for purpose "cookie.name"; reading it as another
  # cookie's signed value must yield nil (purpose isolation)
  read_cookie(cookie_header(["other", signed_name]), :other) { |j| j.signed[:other] }
}

# --- encrypted jar (decrypt direction + format; random IV) -----------

encrypted_discount = set_cookie_value(set_cookie { |j| j.encrypted[:discount] = 45 })
case_run("ck_encrypted_fixture_int") { encrypted_discount }
case_run("ck_encrypted_read_int") {
  read_cookie(cookie_header(["discount", encrypted_discount]), :discount) { |j| j.encrypted[:discount] }
}
case_run("ck_encrypted_tamper_read") {
  tampered = encrypted_discount.dup
  tampered[0] = (tampered[0] == "A" ? "B" : "A")
  read_cookie(cookie_header(["discount", tampered]), :discount) { |j| j.encrypted[:discount] }
}
case_run("ck_encrypted_purpose_mismatch") {
  read_cookie(cookie_header(["secret", encrypted_discount]), :secret) { |j| j.encrypted[:secret] }
}

encrypted_token = set_cookie_value(set_cookie { |j| j.encrypted[:token] = "top secret" })
case_run("ck_encrypted_fixture_str") { encrypted_token }
case_run("ck_encrypted_read_str") {
  read_cookie(cookie_header(["token", encrypted_token]), :token) { |j| j.encrypted[:token] }
}
case_run("ck_encrypted_format") {
  parts = encrypted_token.split("--")
  # b64(ciphertext) + "--" + b64(iv: 12 bytes) + "--" + b64(tag: 16 bytes)
  if parts.size == 3 && parts.all? { |p| p =~ /\A[A-Za-z0-9+\/]+={0,2}\z/ } &&
     Base64.decode64(parts[1]).length == 12 && Base64.decode64(parts[2]).length == 16
    "ok"
  else
    "bad"
  end
}

# --- permanent jar ----------------------------------------------------

case_run("ck_permanent_signed") {
  line = set_cookie { |j| j.permanent.signed[:remember_me] = 42 }
  expires = line[/expires=(.*?)(;|\z)/, 1]
  exp_time = Time.httpdate(expires)
  envelope = JSON.parse(Base64.decode64(set_cookie_value(line).split("--").first))
  rails = envelope["_rails"]
  if exp_time > Time.now && exp_time < Time.now + 20.years + 86400 &&
     rails["exp"].nil? && rails["pur"] == "cookie.remember_me"
    "ok"
  else
    "bad"
  end
}
case_run("ck_permanent_plain") {
  line = set_cookie { |j| j.permanent[:prefers_open_id] = true }
  expires = Time.httpdate(line[/expires=(.*?)(;|\z)/, 1])
  expires > Time.now && expires < Time.now + 20.years + 86400 ? "ok" : "bad"
}
