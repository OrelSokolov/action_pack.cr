# Oracle spec: 1:1 mirror of oracle/cookies_cases.rb (ActionDispatch::Cookies
# из actionpack 8.1.4): plain jar + Set-Cookie options, signed/encrypted/
# permanent jars, purpose-изоляция, tamper/purpose-mismatch чтение.
# Expected — oracle/cookies_expected.yml. Две random-IV фикстуры
# (ck_encrypted_fixture_*) — decrypt-направление. Реверс (порт пишет → гем
# читает) — oracle/verify_cookies.rb.

require "spec"
require "http"
require "base64"
require "json"
require "../src/action_pack_cr"

SECRET = "b3c641c1e9d1e0e4a1e1c6e8e5b7d2f4a9c0d3e6f1a2b4c5d6e7f8a9b0c1d2e3f"

def build_context(cookie : String? = nil, https = false) : HTTP::Server::Context
  headers = HTTP::Headers.new
  headers["Cookie"] = cookie if cookie
  # action_pack не знает о TLS-терминации — https имитируется стандартным
  # прокси-заголовком (в реальном приложении его ставит reverse-proxy)
  headers["X-Forwarded-Proto"] = "https" if https
  request = HTTP::Request.new("GET", "/", headers)
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  HTTP::Server::Context.new(request, response)
end

# Пишет cookie через yield(jar) и возвращает (единственный) Set-Cookie
# или "" (cookie дропнута — например :secure поверх plain HTTP).
def set_cookie(cookie : String? = nil, https = false, &)
  ctx = build_context(cookie, https)
  jar = ActionController::Cookies.new(ctx)
  yield jar
  ctx.response.headers.get?("Set-Cookie").try(&.join("\n")) || ""
end

def read_cookie(header : String, &)
  jar = ActionController::Cookies.new(build_context(header))
  yield jar
end

def cookie_header(name : String, value : String) : String
  "#{name}=#{URI.encode_www_form(value)}"
end

# Значение (escaped) из Set-Cookie строки, как set_cookie_value харнесса.
def set_cookie_value(line : String) : String
  escaped = line.match(/=(.*?);/).try(&.[1]) ||
            line.match(/=(.*)\z/).try(&.[1]) || ""
  URI.decode_www_form(escaped)
end

def render_cookie(v) : String
  case v
  when JSON::Any then render_cookie(v.raw)
  when Bool, Int32, Int64, String then v.inspect
  when Nil then "nil"
  else v.inspect
  end
end

describe "ActionDispatch::Cookies oracle (actionpack 8.1.4)" do
  expected = Hash(String, String).new
  File.read_lines(File.join(__DIR__, "..", "oracle", "cookies_expected.yml")).each do |line|
    id, value = line.split('\t', 2)
    expected[id] = value
  end

  before_all do
    ActionController.cookies_secret_key_base = SECRET
  end
  after_all do
    ActionController.cookies_secret_key_base = nil
  end

  # --- plain jar + Set-Cookie options ---------------------------------

  it "ck_plain_set" do
    line = set_cookie { |j| j["user_name"] = "david" }
    line.inspect.should eq(expected["ck_plain_set"])
  end

  it "ck_plain_escape_set" do
    line = set_cookie { |j| j["q"] = "a+b/c=d e%f" }
    line.inspect.should eq(expected["ck_plain_escape_set"])
  end

  it "ck_opt_expires" do
    line = set_cookie { |j| j.set("login", "XJ-122", expires: Time.utc(2030, 10, 15, 5, 0, 0)) }
    line.inspect.should eq(expected["ck_opt_expires"])
  end

  it "ck_opt_httponly" do
    line = set_cookie { |j| j.set("s", "v", httponly: true) }
    line.inspect.should eq(expected["ck_opt_httponly"])
  end

  it "ck_opt_secure_http" do
    set_cookie { |j| j.set("s", "v", secure: true) }
      .should eq(expected["ck_opt_secure_http"].delete('"'))
  end

  it "ck_opt_secure_https" do
    line = set_cookie(https: true) { |j| j.set("s", "v", secure: true) }
    line.inspect.should eq(expected["ck_opt_secure_https"])
  end

  it "ck_opt_samesite_none" do
    line = set_cookie { |j| j.set("s", "v", same_site: :none) }
    line.inspect.should eq(expected["ck_opt_samesite_none"])
  end

  it "ck_opt_samesite_lax" do
    line = set_cookie { |j| j.set("s", "v", same_site: :lax) }
    line.inspect.should eq(expected["ck_opt_samesite_lax"])
  end

  it "ck_opt_samesite_strict" do
    line = set_cookie { |j| j.set("s", "v", same_site: :strict) }
    line.inspect.should eq(expected["ck_opt_samesite_strict"])
  end

  it "ck_opt_domain" do
    line = set_cookie { |j| j.set("s", "v", domain: "example.com") }
    line.inspect.should eq(expected["ck_opt_domain"])
  end

  it "ck_opt_path" do
    line = set_cookie { |j| j.set("s", "v", path: "/app") }
    line.inspect.should eq(expected["ck_opt_path"])
  end

  it "ck_opt_combo" do
    line = set_cookie do |j|
      j.set("c", "v", expires: Time.utc(2031, 1, 2, 3, 4, 5), httponly: true,
        same_site: :strict, domain: "example.org")
    end
    line.inspect.should eq(expected["ck_opt_combo"])
  end

  it "ck_delete_plain" do
    line = set_cookie(cookie: "gone=1") { |j| j.delete("gone") }
    line.inspect.should eq(expected["ck_delete_plain"])
  end

  it "ck_delete_path" do
    line = set_cookie(cookie: "x=1") { |j| j.delete("x", path: "/app") }
    line.inspect.should eq(expected["ck_delete_path"])
  end

  # --- signed jar (byte-exact, deterministic) --------------------------

  it "ck_signed_int_set" do
    line = set_cookie { |j| j.signed["user_id"] = 123 }
    line.inspect.should eq(expected["ck_signed_int_set"])
  end

  it "ck_signed_str_set" do
    line = set_cookie { |j| j.signed["name"] = "david" }
    line.inspect.should eq(expected["ck_signed_str_set"])
  end

  it "ck_signed_expiring_set" do
    line = set_cookie do |j|
      j.signed.set("login", "XJ-122", expires: Time.utc(2030, 10, 15, 5, 0, 0))
    end
    line.inspect.should eq(expected["ck_signed_expiring_set"])
  end

  it "ck_signed_read_int" do
    signed_user_id = set_cookie_value(set_cookie { |j| j.signed["user_id"] = 123 })
    value = read_cookie(cookie_header("user_id", signed_user_id)) { |j| j.signed["user_id"] }
    render_cookie(value).should eq(expected["ck_signed_read_int"])
  end

  it "ck_signed_read_str" do
    signed_name = set_cookie_value(set_cookie { |j| j.signed["name"] = "david" })
    value = read_cookie(cookie_header("name", signed_name)) { |j| j.signed["name"] }
    render_cookie(value).should eq(expected["ck_signed_read_str"])
  end

  it "ck_signed_raw_read" do
    signed_name = set_cookie_value(set_cookie { |j| j.signed["name"] = "david" })
    value = read_cookie(cookie_header("name", signed_name)) { |j| j["name"] }
    render_cookie(value).should eq(expected["ck_signed_raw_read"])
  end

  it "ck_signed_tamper_read" do
    signed_name = set_cookie_value(set_cookie { |j| j.signed["name"] = "david" })
    tampered = (signed_name[0] == 'A' ? "B" : "A") + signed_name[1..]
    value = read_cookie(cookie_header("name", tampered)) { |j| j.signed["name"] }
    render_cookie(value).should eq(expected["ck_signed_tamper_read"])
  end

  it "ck_signed_purpose_mismatch" do
    signed_name = set_cookie_value(set_cookie { |j| j.signed["name"] = "david" })
    value = read_cookie(cookie_header("other", signed_name)) { |j| j.signed["other"] }
    render_cookie(value).should eq(expected["ck_signed_purpose_mismatch"])
  end

  # --- encrypted jar (decrypt direction + format; random IV) -----------

  it "ck_encrypted_read_int" do
    fixture = expected["ck_encrypted_fixture_int"].delete('"')
    value = read_cookie(cookie_header("discount", fixture)) { |j| j.encrypted["discount"] }
    render_cookie(value).should eq(expected["ck_encrypted_read_int"])
  end

  it "ck_encrypted_tamper_read" do
    fixture = expected["ck_encrypted_fixture_int"].delete('"')
    tampered = (fixture[0] == 'A' ? "B" : "A") + fixture[1..]
    value = read_cookie(cookie_header("discount", tampered)) { |j| j.encrypted["discount"] }
    render_cookie(value).should eq(expected["ck_encrypted_tamper_read"])
  end

  it "ck_encrypted_purpose_mismatch" do
    fixture = expected["ck_encrypted_fixture_int"].delete('"')
    value = read_cookie(cookie_header("secret", fixture)) { |j| j.encrypted["secret"] }
    render_cookie(value).should eq(expected["ck_encrypted_purpose_mismatch"])
  end

  it "ck_encrypted_read_str" do
    fixture = expected["ck_encrypted_fixture_str"].delete('"')
    value = read_cookie(cookie_header("token", fixture)) { |j| j.encrypted["token"] }
    render_cookie(value).should eq(expected["ck_encrypted_read_str"])
  end

  it "ck_encrypted_format" do
    token = set_cookie { |j| j.encrypted["token"] = "top secret" }
      .try { |line| set_cookie_value(line) }
    parts = token.split("--")
    result = if parts.size == 3 &&
                 parts.all? { |p| p =~ /\A[A-Za-z0-9+\/]+={0,2}\z/ } &&
                 Base64.decode(parts[1]).size == 12 && Base64.decode(parts[2]).size == 16
               "ok"
             else
               "bad"
             end
    result.inspect.should eq(expected["ck_encrypted_format"])
  end

  # --- permanent jar ----------------------------------------------------

  it "ck_permanent_signed" do
    line = set_cookie { |j| j.permanent.signed["remember_me"] = 42 }
    expires = line.match(/expires=(.*?)(;|\z)/).try(&.[1]).not_nil!
    exp_time = Time::Format::HTTP_DATE.parse(expires)
    envelope = JSON.parse(Base64.decode_string(set_cookie_value(line).split("--").first))
    rails = envelope["_rails"]
    ok = exp_time > Time.utc && exp_time < Time.utc + 20.years + 1.day &&
         rails["exp"].raw.nil? && rails["pur"] == "cookie.remember_me"
    render_cookie(ok ? "ok" : "bad").should eq(expected["ck_permanent_signed"])
  end

  it "ck_permanent_plain" do
    line = set_cookie { |j| j.permanent["prefers_open_id"] = "true" }
    expires = line.match(/expires=(.*?)(;|\z)/).try(&.[1]).not_nil!
    exp_time = Time::Format::HTTP_DATE.parse(expires)
    ok = exp_time > Time.utc && exp_time < Time.utc + 20.years + 1.day
    render_cookie(ok ? "ok" : "bad").should eq(expected["ck_permanent_plain"])
  end

  # --- реверс: порт пишет → оригинальный гем читает --------------------

  it "reverse roundtrip read by original gem" do
    reverse_cases = [] of {String, String, String, String}
    wire = set_cookie_value(set_cookie { |j| j.signed["user_id"] = 123 })
    reverse_cases << {"user_id", "signed", "123", wire}
    wire = set_cookie_value(set_cookie { |j| j.signed["name"] = "david" })
    reverse_cases << {"name", "signed", %q("david"), wire}
    wire = set_cookie_value(set_cookie do |j|
      j.signed.set("login", "XJ-122", expires: Time.utc(2035, 10, 15, 5, 0, 0))
    end)
    reverse_cases << {"login", "signed", %q("XJ-122"), wire}
    wire = set_cookie_value(set_cookie { |j| j.encrypted["discount"] = 45 })
    reverse_cases << {"discount", "encrypted", "45", wire}
    wire = set_cookie_value(set_cookie { |j| j.encrypted["token"] = "top secret" })
    reverse_cases << {"token", "encrypted", %q("top secret"), wire}
    wire = set_cookie_value(set_cookie { |j| j.permanent.signed["remember_me"] = 42 })
    reverse_cases << {"remember_me", "signed", "42", wire}

    path = File.join(Dir.tempdir, "crails_verify_cookies_#{Random::Secure.hex(8)}.tsv")
    File.write(path, reverse_cases.map(&.join("\t")).join("\n"))
    status = Process.run("ruby",
      [File.join(__DIR__, "..", "oracle", "verify_cookies.rb"), path],
      output: output = IO::Memory.new)
    File.delete(path)
    status.success?.should be_true, "ruby verify_cookies failed:\n#{output}"
    output.to_s.scan(/\tOK/).size.should eq(reverse_cases.size)
  end

  # --- юниты: roundtrip, secret-хук, session/flash ---------------------

  it "signed/encrypted roundtrip" do
    ctx = build_context
    jar = ActionController::Cookies.new(ctx)
    jar.signed["n"] = 7
    jar.encrypted["e"] = "v"
    jar.permanent.signed["p"] = 1
    wire = jar["n"].not_nil!
    ActionController::Cookies.new(build_context(cookie_header("n", wire)))
      .signed["n"].try(&.raw).should eq(7)
  end

  it "signed jar raises without secret" do
    old_env = ENV.delete("SECRET_KEY_BASE")
    ActionController.cookies_secret_key_base = nil
    ctx = build_context
    jar = ActionController::Cookies.new(ctx)
    expect_raises RuntimeError do
      jar.signed["x"] = 1
    end
    ENV["SECRET_KEY_BASE"] = old_env if old_env
  end

  it "session rides signed when secret is set, legacy fallback read" do
    ActionController.cookies_secret_key_base = SECRET
    ctx = build_context
    cookies = ActionController::Cookies.new(ctx)
    session = ActionController::Session.new(cookies)
    session["user_id"] = "42"
    wire = cookies[ActionController::Session::KEY].not_nil!
    wire.includes?("--").should be_true # подписана
    # следующая «страница»: сессия читается обратно
    cookies2 = ActionController::Cookies.new(
      build_context(cookie_header(ActionController::Session::KEY, wire)))
    ActionController::Session.new(cookies2)["user_id"].should eq("42")
    # legacy неподписанная cookie тоже читается (переходный режим)
    legacy = URI.encode_www_form(
      Base64.strict_encode({"user_id" => "legacy"}.to_json))
    cookies3 = ActionController::Cookies.new(
      build_context("#{ActionController::Session::KEY}=#{legacy}"))
    ActionController::Session.new(cookies3)["user_id"].should eq("legacy")
    ActionController.cookies_secret_key_base = nil
  end
end
