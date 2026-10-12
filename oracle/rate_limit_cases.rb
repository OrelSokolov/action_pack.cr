# Oracle cases for ActionController::RateLimiting (Iteration 12).
#
# Run against the ORIGINAL gem:
#   ruby oracle/rate_limit_cases.rb > oracle/rate_limit_expected.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in
# spec/rate_limit_oracle_spec.cr; the Crystal port must reproduce
# rate_limit_expected.yml exactly (captured from actionpack 8.1.4).
#
# Bare controllers (no Rails app): each controller gets an explicit
# MemoryStore via `store:` so cases are hermetic. 429 responses come
# from wrapping the controller endpoint in ActionDispatch::ShowExceptions
# (+ PublicExceptions for the error body), exactly like a real stack.

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

EVENTS = []
ActiveSupport::Notifications.subscribe("rate_limit.action_controller") do |event|
  EVENTS << event.payload
end

PUBLIC_DIR = Dir.mktmpdir

# --- controllers --------------------------------------------------------

class PlainController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 3, within: 60.seconds, store: STORE

  def index
    render plain: "ok"
  end
end

class ByHeaderController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 2, within: 60.seconds, store: STORE,
             by: -> { request.headers["X-Key"] }

  def index
    render plain: "ok"
  end
end

class BusyController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 1, within: 60.seconds, store: STORE, with: :too_busy

  def index
    render plain: "ok"
  end

  private

  def too_busy
    render plain: "busy", status: 503
  end
end

class NamedController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 1, within: 60.seconds, store: STORE, name: "short"
  rate_limit to: 3, within: 60.seconds, store: STORE, name: "long"

  def index
    render plain: "ok"
  end
end

class ScopeAController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 2, within: 60.seconds, store: STORE, scope: "shared"

  def index
    render plain: "a"
  end
end

class ScopeBController < ActionController::Base
  rate_limit to: 2, within: 60.seconds, store: ScopeAController::STORE, scope: "shared"

  def index
    render plain: "b"
  end
end

class OnlyController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 2, within: 60.seconds, store: STORE, only: :create

  def index
    render plain: "index"
  end

  def create
    render plain: "created"
  end
end

class ShortWindowController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 1, within: 0.3.seconds, store: STORE

  def index
    render plain: "ok"
  end
end

class NullStoreController < ActionController::Base
  STORE = ActiveSupport::Cache::NullStore.new
  rate_limit to: 1, within: 60.seconds, store: STORE

  def index
    render plain: "ok"
  end
end

# --- request helper ------------------------------------------------------

def status(endpoint, remote_ip: "10.0.0.1", headers: {})
  app = ActionDispatch::ShowExceptions.new(endpoint, ActionDispatch::PublicExceptions.new(PUBLIC_DIR))
  env = Rack::MockRequest.env_for("/", headers.merge("REMOTE_ADDR" => remote_ip))
  status, = app.call(env)
  status
end

def get200(controller, action = :index, **opts)
  status(controller.action(action), **opts)
end

# --- cases ---------------------------------------------------------------

case_run("default_first_3_pass") do
  (1..3).map { get200(PlainController) }.join(",")
end

case_run("default_4th_is_429") { get200(PlainController) }
case_run("default_5th_still_429") { get200(PlainController) }

case_run("separate_ip_buckets") do
  get200(PlainController, remote_ip: "10.0.0.2")
end

case_run("instrument_payload_counts") do
  EVENTS.select { |p| p[:name].nil? }.map { |p| p[:count] }.join(",")
end

case_run("instrument_cache_key") do
  EVENTS.last[:cache_key]
end

case_run("instrument_payload_keys") do
  (EVENTS.last.keys - [:exception, :exception_object]).sort.join(",")
end

case_run("custom_by_header_buckets") do
  a1 = get200(ByHeaderController, headers: { "HTTP_X_KEY" => "key-a" })
  a2 = get200(ByHeaderController, headers: { "HTTP_X_KEY" => "key-a" })
  b1 = get200(ByHeaderController, headers: { "HTTP_X_KEY" => "key-b" })
  [a1, a2, b1].join(",")
end

case_run("custom_by_429_cache_key") do
  get200(ByHeaderController, headers: { "HTTP_X_KEY" => "key-a" }) # 3rd for key-a -> 429
  EVENTS.select { |p| p[:cache_key].include?("key-a") }.last[:cache_key]
end

case_run("with_symbol_handler") do
  get200(BusyController) # 1st: ok
  get200(BusyController) # 2nd: custom handler
end

case_run("named_two_limits") do
  n1 = get200(NamedController)
  n2 = get200(NamedController) # 2nd: "short" (to=1) exceeded -> 429
  [n1, n2].join(",")
end

case_run("named_limits_share_request") do
  EVENTS.select { |p| p[:name] }.group_by { |p| p[:name] }
        .map { |name, ps| "#{name}:#{ps.map { |p| p[:count] }.join(",")}" }.sort.join(" ")
end

case_run("scope_shared_between_controllers") do
  a1 = get200(ScopeAController)
  a2 = get200(ScopeAController)
  a3 = get200(ScopeAController) # over shared limit
  b1 = get200(ScopeBController) # same shared bucket -> 429
  [a1, a2, a3, b1].join(",")
end

case_run("only_option_index_unlimited") do
  (1..4).map { get200(OnlyController, :index) }.join(",")
end

case_run("only_option_create_limited") do
  c1 = get200(OnlyController, :create)
  c2 = get200(OnlyController, :create)
  c3 = get200(OnlyController, :create) # 3rd -> 429
  [c1, c2, c3].join(",")
end

case_run("expires_window_semantics") do
  ShortWindowController::STORE.clear
  s1 = get200(ShortWindowController)        # t=0: count=1 -> 200
  s2 = get200(ShortWindowController)        # t~0: count=2 -> 429
  sleep 0.5                                 # > within since first request
  s3 = get200(ShortWindowController)        # fixed window from 1st -> 200; sliding from 2nd -> 429
  [s1, s2, s3].join(",")
end

case_run("null_store_no_limit") do
  (1..4).map { get200(NullStoreController) }.join(",")
end
