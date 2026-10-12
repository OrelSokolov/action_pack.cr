# Oracle cases for ActionController::RequestForgeryProtection (Iteration 12).
#
# Run against the ORIGINAL gem:
#   ruby oracle/csrf_cases.rb > oracle/csrf_expected.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in
# railties.cr/spec/csrf_spec.cr; the Crystal port must reproduce
# csrf_expected.yml exactly (captured from actionpack 8.1.4).
#
# Bare controllers (no Rails app) with a real session middleware
# (ActionDispatch::Session::CacheStore over a MemoryStore) and
# ActionDispatch::ShowExceptions — 422 responses map exactly like a
# production stack. Controllers mirror the CRails port 1:1 (same
# actions, same routes); requests go through real HTTP cookie jars so
# token/session lifecycle is exercised end to end.

gem "actionpack", "= 8.1.4"
gem "activesupport", "= 8.1.4"
gem "rack", "~> 3"
require "action_controller"
require "active_support/notifications"
require "tmpdir"

def render(v)
  case v
  when String then v
  else v.inspect
  end
end

def case_run(id)
  puts "#{id}\t#{render(yield)}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

CACHE = ActiveSupport::Cache::MemoryStore.new
PUBLIC_DIR = Dir.mktmpdir

# --- controllers (mirrored 1:1 in railties.cr/spec/csrf_spec.cr) ---------

class CsExceptionController < ActionController::Base
  protect_from_forgery with: :exception

  def token
    render plain: form_authenticity_token
  end

  def create
    render plain: "created"
  end
end

class CsNullSessionController < ActionController::Base
  protect_from_forgery with: :null_session

  def set_mark
    session[:mark] = "v"
    render plain: "set"
  end

  def show_mark
    render plain: session[:mark].to_s
  end
end

class CsResetSessionController < ActionController::Base
  protect_from_forgery with: :reset_session

  def set_mark
    session[:mark] = "v"
    render plain: "set"
  end

  def show_mark
    render plain: session[:mark].to_s
  end
end

class CsSkippedController < ActionController::Base
  protect_from_forgery with: :exception
  skip_forgery_protection

  def create
    render plain: "created"
  end
end

class CsExceptController < ActionController::Base
  protect_from_forgery with: :exception, except: :create

  def create
    render plain: "created"
  end

  def update
    render plain: "updated"
  end
end

class CsPerFormController < ActionController::Base
  protect_from_forgery with: :exception
  self.per_form_csrf_tokens = true

  def form_token
    render plain: form_authenticity_token(form_options: { action: "/cf_create", method: :post })
  end

  def global_token
    render plain: form_authenticity_token
  end

  def cf_create
    render plain: "created"
  end

  def other_create
    render plain: "other"
  end
end

class CsOriginController < ActionController::Base
  protect_from_forgery with: :exception
  self.forgery_protection_origin_check = true

  def token
    render plain: form_authenticity_token
  end

  def create
    render plain: "created"
  end
end

class CsAllowOffController < ActionController::Base
  protect_from_forgery with: :exception
  self.allow_forgery_protection = false

  def create
    render plain: "created"
  end
end

class CsJsController < ActionController::Base
  protect_from_forgery with: :exception

  def script
    render plain: "// js", content_type: "text/javascript"
  end
end

# --- request helper ------------------------------------------------------

class Jar
  def initialize
    @cookies = {}
  end

  def absorb(headers)
    Array(headers["Set-Cookie"]).each do |c|
      k, v = c.split("=", 2)
      v = v.split(";").first.to_s
      v.empty? ? @cookies.delete(k) : @cookies[k] = v
    end
  end

  def header
    @cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
  end
end

# status via the ShowExceptions stack (422 like production), cookies kept
# in the given jar across requests.
def csrf_status(controller, action, jar, method: :get, path: nil, params: {},
                headers: {}, show_exceptions: true)
  endpoint = ->(env) { controller.action(action).call(env) }
  wrapped = show_exceptions ?
    ActionDispatch::ShowExceptions.new(endpoint, ActionDispatch::PublicExceptions.new(PUBLIC_DIR)) :
    endpoint
  flashed = ActionDispatch::Flash.new(wrapped)
  session = ActionDispatch::Session::CacheStore.new(flashed, cache: CACHE, key: "_csrf_oracle_session")
  app = ActionDispatch::Cookies.new(session)

  env = Rack::MockRequest.env_for(path || "/#{action}", method: method, params: params)
  env = headers.merge(env)
  env["HTTP_COOKIE"] = [env["HTTP_COOKIE"] || "", jar.header].reject(&:empty?).join("; ")
  status, headers, = app.call(env)
  jar.absorb(headers)
  status
end

def csrf_body(controller, action, jar, method: :get, path: nil, params: {})
  endpoint = ->(env) { controller.action(action).call(env) }
  flashed = ActionDispatch::Flash.new(endpoint)
  session = ActionDispatch::Session::CacheStore.new(flashed, cache: CACHE, key: "_csrf_oracle_session")
  app = ActionDispatch::Cookies.new(session)
  env = Rack::MockRequest.env_for(path || "/#{action}", method: method, params: params)
  env["HTTP_COOKIE"] = [env["HTTP_COOKIE"] || "", jar.header].reject(&:empty?).join("; ")
  status, headers, body = app.call(env)
  jar.absorb(headers)
  body.each.to_a.join
end

# --- cases: :exception strategy ------------------------------------------

case_run("exc_get_ok") do
  jar = Jar.new
  csrf_status(CsExceptionController, :token, jar)
end

case_run("exc_post_no_token_422") do
  jar = Jar.new
  csrf_status(CsExceptionController, :create, jar, method: :post)
end

case_run("exc_post_garbage_token_422") do
  jar = Jar.new
  csrf_status(CsExceptionController, :create, jar, method: :post, params: { authenticity_token: "garbage!!!" })
end

case_run("exc_post_empty_token_422") do
  jar = Jar.new
  csrf_status(CsExceptionController, :create, jar, method: :post, params: { authenticity_token: "" })
end

case_run("exc_post_valid_global_token_ok") do
  jar = Jar.new
  token = csrf_body(CsExceptionController, :token, jar)
  csrf_status(CsExceptionController, :create, jar, method: :post,
              params: { authenticity_token: token })
end

case_run("exc_post_header_token_ok") do
  jar = Jar.new
  token = csrf_body(CsExceptionController, :token, jar)
  csrf_status(CsExceptionController, :create, jar, method: :post,
              headers: { "HTTP_X_CSRF_TOKEN" => token })
end

case_run("exc_token_rotates") do
  jar = Jar.new
  t1 = csrf_body(CsExceptionController, :token, jar)
  t2 = csrf_body(CsExceptionController, :token, jar)
  (t1 != t2).to_s
end

case_run("exc_token_reusable") do
  jar = Jar.new
  token = csrf_body(CsExceptionController, :token, jar)
  s1 = csrf_status(CsExceptionController, :create, jar, method: :post, params: { authenticity_token: token })
  s2 = csrf_status(CsExceptionController, :create, jar, method: :post, params: { authenticity_token: token })
  [s1, s2].join(",")
end

case_run("exc_cross_session_token_422") do
  jar_a = Jar.new
  token = csrf_body(CsExceptionController, :token, jar_a)
  jar_b = Jar.new # fresh browser: different session
  csrf_status(CsExceptionController, :create, jar_b, method: :post, params: { authenticity_token: token })
end

case_run("exc_put_patch_delete_no_token") do
  jar = Jar.new
  [
    csrf_status(CsExceptionController, :create, jar, method: :put),
    csrf_status(CsExceptionController, :create, jar, method: :patch),
    csrf_status(CsExceptionController, :create, jar, method: :delete)
  ].join(",")
end

case_run("exc_unmasked_token_rejected") do
  jar = Jar.new
  # unmask the real token from a masked one and send it raw
  masked = csrf_body(CsExceptionController, :token, jar)
  decoded = Base64.urlsafe_decode64(masked)
  raw = decoded[0, 32].bytes.zip(decoded[32, 32].bytes).map { |a, b| a ^ b }.pack("C*")
  csrf_status(CsExceptionController, :create, jar, method: :post,
              params: { authenticity_token: Base64.urlsafe_encode64(raw, padding: false) })
end

case_run("exc_raise_class") do
  jar = Jar.new
  csrf_status(CsExceptionController, :create, jar, method: :post, show_exceptions: false)
end

# --- cases: :null_session / :reset_session -------------------------------

case_run("null_post_no_token_200") do
  jar = Jar.new
  csrf_status(CsNullSessionController, :show_mark, jar, method: :post)
end

case_run("null_session_emptied_during_request") do
  jar = Jar.new
  csrf_status(CsNullSessionController, :set_mark, jar)          # session[:mark] = "v"
  csrf_body(CsNullSessionController, :show_mark, jar, method: :post) # unverified POST
end

case_run("null_session_not_reset_after") do
  jar = Jar.new
  csrf_status(CsNullSessionController, :set_mark, jar)
  csrf_status(CsNullSessionController, :show_mark, jar, method: :post)
  csrf_body(CsNullSessionController, :show_mark, jar)           # original session intact
end

case_run("reset_session_emptied_permanently") do
  jar = Jar.new
  csrf_status(CsResetSessionController, :set_mark, jar)
  during = csrf_body(CsResetSessionController, :show_mark, jar, method: :post)
  after = csrf_body(CsResetSessionController, :show_mark, jar)
  [during, after].join(",")
end

# --- cases: skip / except --------------------------------------------------

case_run("skip_forgery_protection_post_ok") do
  jar = Jar.new
  csrf_status(CsSkippedController, :create, jar, method: :post)
end

case_run("except_create_post_ok_update_422") do
  jar = Jar.new
  [
    csrf_status(CsExceptController, :create, jar, method: :post),
    csrf_status(CsExceptController, :update, jar, method: :post)
  ].join(",")
end

# --- cases: per-form tokens ------------------------------------------------

case_run("per_form_valid_token_ok") do
  jar = Jar.new
  token = csrf_body(CsPerFormController, :form_token, jar)
  csrf_status(CsPerFormController, :cf_create, jar, method: :post, path: "/cf_create",
              params: { authenticity_token: token })
end

case_run("per_form_wrong_action_422") do
  jar = Jar.new
  token = csrf_body(CsPerFormController, :form_token, jar) # bound to /cf_create
  csrf_status(CsPerFormController, :other_create, jar, method: :post, path: "/other_create",
              params: { authenticity_token: token })
end

case_run("per_form_global_token_ok") do
  jar = Jar.new
  token = csrf_body(CsPerFormController, :global_token, jar)
  csrf_status(CsPerFormController, :cf_create, jar, method: :post, path: "/cf_create",
              params: { authenticity_token: token })
end

# --- cases: origin check ---------------------------------------------------

case_run("origin_bad_422") do
  jar = Jar.new
  token = csrf_body(CsOriginController, :token, jar)
  csrf_status(CsOriginController, :create, jar, method: :post,
              params: { authenticity_token: token }, headers: { "HTTP_ORIGIN" => "http://evil.com" })
end

case_run("origin_matching_ok") do
  jar = Jar.new
  token = csrf_body(CsOriginController, :token, jar)
  csrf_status(CsOriginController, :create, jar, method: :post,
              params: { authenticity_token: token }, headers: { "HTTP_ORIGIN" => "http://example.org" })
end

case_run("origin_absent_ok") do
  jar = Jar.new
  token = csrf_body(CsOriginController, :token, jar)
  csrf_status(CsOriginController, :create, jar, method: :post,
              params: { authenticity_token: token })
end

# --- cases: allow_forgery_protection off -----------------------------------

case_run("allow_off_post_ok") do
  jar = Jar.new
  csrf_status(CsAllowOffController, :create, jar, method: :post)
end

# --- cases: cross-origin JavaScript responses -------------------------------

case_run("js_non_xhr_422") do
  jar = Jar.new
  csrf_status(CsJsController, :script, jar, headers: { "HTTP_ACCEPT" => "text/javascript" })
end

case_run("js_xhr_ok") do
  jar = Jar.new
  csrf_status(CsJsController, :script, jar,
              headers: { "HTTP_ACCEPT" => "text/javascript", "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest" })
end

case_run("js_cross_origin_raise_class") do
  jar = Jar.new
  csrf_status(CsJsController, :script, jar, show_exceptions: false,
              headers: { "HTTP_ACCEPT" => "text/javascript" })
end
