require "spec"
require "http"
require "../src/action_pack_cr"

abstract class ApplicationController < ActionController::Base
end

class PostsController < ApplicationController
  def show
    @title = "Hello <Post>"
  end

  def plain
    render plain: "just text"
  end

  def redirect
    redirect_to "/somewhere"
  end

  def no_template
    @title = "orphan"
  end

  def streamed
    @title = "TS body"
  end
end

private def build_context(method : String, path : String, query : String? = nil, accept : String? = nil) : Tuple(HTTP::Server::Context, IO::Memory)
  headers = HTTP::Headers.new
  headers["Accept"] = accept if accept
  request = HTTP::Request.new(method, path + (query ? "?#{query}" : ""), headers)
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  {HTTP::Server::Context.new(request, response), io}
end

private def run_action(context : HTTP::Server::Context, params : Hash(String, String) = {} of String => String, action : String = "show") : Nil
  controller = PostsController.new(context)
  controller.__set_params(params)
  controller.__run_action(action)
  context.response.close
end

# Host for the generated `*_path`/`*_url` helpers: `macro method_missing`
# only fires for calls lexically inside the class body, so each helper
# exercised by the specs gets a thin wrapper.
class UrlHelperHost
  include CRails::Routes::UrlHelpers

  class ParamModel
    def to_param : String
      "7"
    end
  end

  def h_root_path
    root_path
  end

  def h_room_path(*args, **opts)
    room_path(*args, **opts)
  end

  def h_room_message_path(*args, **opts)
    room_message_path(*args, **opts)
  end

  def h_room_at_message_path(*args, **opts)
    room_at_message_path(*args, **opts)
  end

  def h_oops_path
    oops_path
  end

  def h_up_path
    up_path
  end

  def h_room_message_path_one_arg
    room_message_path(1)
  end

  def h_room_url(*args, **opts)
    room_url(*args, **opts)
  end
end

class UrlHelperOriginHost
  include CRails::Routes::UrlHelpers

  def origin : String
    "https://campfire.test"
  end

  def h_room_url(*args, **opts)
    room_url(*args, **opts)
  end
end

describe "CRails::Routes" do
  it "matches root" do
    set = CRails::Routes::RouteSet.new
    set.draw do
      root "welcome#index"
      get "/posts/:id", to: "posts#show", as: "post"
    end
    match = set.match("GET", "/")
    match.should_not be_nil
    match.not_nil!.route.controller.should eq("welcome")
    match.not_nil!.route.action.should eq("index")
    match.not_nil!.route.name.should eq("root")
  end

  it "extracts :params and decodes them" do
    set = CRails::Routes::RouteSet.new
    set.draw { get "/posts/:id", to: "posts#show" }
    match = set.match("GET", "/posts/hello%20world").not_nil!
    match.params["id"].should eq("hello world")
  end

  it "does not match wrong verb or path" do
    set = CRails::Routes::RouteSet.new
    set.draw { get "/posts/:id", to: "posts#show" }
    set.match("POST", "/posts/1").should be_nil
    set.match("GET", "/posts").should be_nil
    set.match("GET", "/posts/1/extra").should be_nil
  end

  it "rejects routes without `to:`" do
    set = CRails::Routes::RouteSet.new
    expect_raises ArgumentError do
      set.draw { get "/oops" }
    end
  end

  it "resources draws the seven RESTful routes with Rails names" do
    set = CRails::Routes::RouteSet.new
    set.draw { resources :posts }
    table = set.routes.map { |r| {r.verb, r.pattern, r.controller, r.action, r.name} }
    table.should eq([
      {"GET", "/posts", "posts", "index", "posts"},
      {"GET", "/posts/new", "posts", "new", "new_post"},
      {"GET", "/posts/:id/edit", "posts", "edit", "edit_post"},
      {"GET", "/posts/:id", "posts", "show", "post"},
      {"POST", "/posts", "posts", "create", nil},
      {"PATCH", "/posts/:id", "posts", "update", nil},
      {"PUT", "/posts/:id", "posts", "update", nil},
      {"DELETE", "/posts/:id", "posts", "destroy", nil},
    ])
    set.match("GET", "/posts").not_nil!.route.name.should eq("posts")
    set.match("GET", "/posts/42").not_nil!.params["id"].should eq("42")
    set.match("DELETE", "/posts/42").should_not be_nil
    set.match("GET", "/posts/new").not_nil!.route.action.should eq("new")
  end

  it "resources honors only/except, controller and param overrides" do
    set = CRails::Routes::RouteSet.new
    set.draw do
      scope path: "rooms" do
        resources :opens, only: [:new, :create, :edit, :update],
          controller: "rooms", param: :room_id, defaults: {kind: "opens"}
      end
    end
    table = set.routes.map { |r| {r.verb, r.pattern, r.controller, r.action} }
    table.should eq([
      {"GET", "/rooms/opens/new", "rooms", "new"},
      {"GET", "/rooms/opens/:room_id/edit", "rooms", "edit"},
      {"POST", "/rooms/opens", "rooms", "create"},
      {"PATCH", "/rooms/opens/:room_id", "rooms", "update"},
      {"PUT", "/rooms/opens/:room_id", "rooms", "update"},
    ])
    set.routes.each { |r| r.defaults.should eq({"kind" => "opens"}) }
    match = set.match("POST", "/rooms/opens").not_nil!
    match.params["kind"].should eq("opens")
    set.match("GET", "/rooms/opens/2/edit").not_nil!.params["room_id"].should eq("2")
  end

  it "nested resources draw member paths with parent params" do
    set = CRails::Routes::RouteSet.new
    set.draw do
      resources :rooms, only: [:show, :destroy] do
        resources :messages, except: [:new], param: :message_id
        get "involvement", to: "rooms#involvement"
        get "@:message_id", to: "rooms#show", as: :at_message
      end
    end
    table = set.routes.map { |r| {r.verb, r.pattern, r.controller, r.action, r.name} }
    table.should contain({"GET", "/rooms/:id", "rooms", "show", "room"})
    table.should contain({"GET", "/rooms/:id/messages", "messages", "index", "room_messages"})
    table.should contain({"GET", "/rooms/:id/messages/:message_id/edit", "messages", "edit", "edit_room_message"})
    table.should contain({"DELETE", "/rooms/:id/messages/:message_id", "messages", "destroy", nil})
    table.should contain({"GET", "/rooms/:id/involvement", "rooms", "involvement", nil})
    table.should_not contain({"GET", "/rooms/:id/messages/new", "messages", "new", "new_room_message"})
    match = set.match("GET", "/rooms/1/messages/42").not_nil!
    match.params["id"].should eq("1")
    match.params["message_id"].should eq("42")
    set.match("GET", "/rooms/1/@99").not_nil!.route.name.should eq("room_at_message")
  end

  it "member/collection blocks and on: option scope custom routes" do
    set = CRails::Routes::RouteSet.new
    set.draw do
      resources :searches, only: [:index, :create] do
        delete "clear", on: :collection
        post "refresh", on: :member
      end
    end
    set.match("DELETE", "/searches/clear").should_not be_nil
    set.match("POST", "/searches/5/refresh").not_nil!.params["id"].should eq("5")
  end

  it "resource draws singular routes with a pluralized controller" do
    set = CRails::Routes::RouteSet.new
    set.draw do
      resource :session, only: [:new, :create, :destroy] do
        resources :transfers, only: [:show, :update]
      end
    end
    table = set.routes.map { |r| {r.verb, r.pattern, r.controller, r.action} }
    table.should eq([
      {"GET", "/session/new", "sessions", "new"},
      {"POST", "/session", "sessions", "create"},
      {"DELETE", "/session", "sessions", "destroy"},
      {"GET", "/session/transfers/:id", "transfers", "show"},
      {"PATCH", "/session/transfers/:id", "transfers", "update"},
      {"PUT", "/session/transfers/:id", "transfers", "update"},
    ])
  end

  it "scope nests paths, names and controller modules" do
    set = CRails::Routes::RouteSet.new
    set.draw do
      scope path: "session", as: "session" do
        get "/transfers/:id", to: "session_transfers#show"
      end
      scope path: "rooms", as: "rooms" do
        resources :directs, only: [:new, :create]
        get "/directs/:room_id/edit", to: "rooms#edit"
      end
      scope path: ":bot_key", as: :bot do
        get "messages", to: "messages#bot_index"
      end
    end
    table = set.routes.map { |r| {r.verb, r.pattern, r.controller, r.action, r.name} }
    table.should contain({"GET", "/session/transfers/:id", "session_transfers", "show", nil})
    set.match("GET", "/session/transfers/7").not_nil!.params["id"].should eq("7")
    table.should contain({"GET", "/rooms/directs/new", "directs", "new", "new_rooms_direct"})
    table.should contain({"GET", "/rooms/directs/:room_id/edit", "rooms", "edit", nil})
    table.should contain({"GET", "/:bot_key/messages", "messages", "bot_index", nil})
  end

  it "namespace prefixes path, module and name" do
    set = CRails::Routes::RouteSet.new
    set.draw do
      namespace :admin do
        resources :posts, only: [:index]
        get "/dashboard", to: "stats#show", as: :dashboard
      end
    end
    table = set.routes.map { |r| {r.verb, r.pattern, r.controller, r.action, r.name} }
    table.should contain({"GET", "/admin/posts", "admin/posts", "index", "admin_posts"})
    table.should contain({"GET", "/admin/dashboard", "admin/stats", "show", "admin_dashboard"})
  end

  it "scope module prefixes explicit to: targets unless controller is absolute" do
    set = CRails::Routes::RouteSet.new
    set.draw do
      scope module: "rooms" do
        get "/refresh", to: "refreshes#show"
        get "/settings", to: "/rooms#settings"
      end
    end
    table = set.routes.map { |r| {r.controller, r.action} }
    table.should contain({"rooms/refreshes", "show"})
    table.should contain({"rooms", "settings"})
  end

  it "defaults fill params the path leaves unset; segment params win" do
    set = CRails::Routes::RouteSet.new
    set.draw do
      scope defaults: {kind: "opens"} do
        get "/rooms/:kind/new", to: "rooms#new"
        get "/rooms/new", to: "rooms#new", as: "literal"
      end
    end
    set.match("GET", "/rooms/closeds/new").not_nil!.params["kind"].should eq("closeds")
    set.match("GET", "/rooms/new").not_nil!.params["kind"].should eq("opens")
  end
end

describe "CRails::Routes::UrlHelpers" do
  it "generates *_path helpers with Rails semantics" do
    set = CRails::Routes::RouteSet.new
    set.draw do
      root "welcome#show"
      get "/up", to: "up#show"
      resources :rooms, only: [:show] do
        resources :messages, only: [:show], param: :message_id
        get "@:message_id", to: "rooms#show", as: :at_message
      end
    end
    CRails::Routes::UrlHelpers.route_set = set
    host = UrlHelperHost.new

    host.h_root_path.should eq("/")
    host.h_room_path(1).should eq("/rooms/1")
    host.h_room_path(1_i64).should eq("/rooms/1")
    host.h_room_path("hello world").should eq("/rooms/hello+world")
    host.h_room_message_path(1, 2).should eq("/rooms/1/messages/2")
    host.h_room_at_message_path(1, 2).should eq("/rooms/1/@2")

    # named opts → query, anchor → fragment
    host.h_room_path(1, v: 3).should eq("/rooms/1?v=3")
    host.h_room_path(1, v: 3, anchor: "m2").should eq("/rooms/1?v=3#m2")
    # extra positional args go to the query string (key = value)
    host.h_room_path(1, 2).should eq("/rooms/1?2=2")
    # to_param objects
    host.h_room_path(UrlHelperHost::ParamModel.new).should eq("/rooms/7")

    # unknown name → ArgumentError (UrlGenerationError analogue)
    expect_raises ArgumentError, "No route named oops" do
      host.h_oops_path
    end
    # unnamed route — no helper
    expect_raises ArgumentError, "No route named up" do
      host.h_up_path
    end
    # not enough args
    expect_raises ArgumentError do
      host.h_room_message_path_one_arg
    end
  end

  it "generates *_url from the context origin, falling back to the default" do
    set = CRails::Routes::RouteSet.new
    set.draw { resources :rooms, only: [:show] }
    CRails::Routes::UrlHelpers.route_set = set
    CRails::Routes::UrlHelpers.default_url_origin = "https://fallback.test"

    UrlHelperOriginHost.new.h_room_url(1).should eq("https://campfire.test/rooms/1")
    UrlHelperHost.new.h_room_url(1).should eq("https://fallback.test/rooms/1")
    CRails::Routes::UrlHelpers.default_url_origin = "http://localhost"
  end

  it "builds the root path without extra args" do
    set = CRails::Routes::RouteSet.new
    set.draw { root "welcome#show" }
    CRails::Routes::UrlHelpers.route_set = set
    UrlHelperHost.new.h_root_path.should eq("/")
  end
end

describe "ActionController::Dispatch codegen" do
  it "resolves controller names to classes" do
    ActionController::Dispatch.resolve("posts").should eq(PostsController)
    ActionController::Dispatch.resolve("nope").should be_nil
  end
end

describe "ActionController::Base rendering" do
  it "default-renders template with layout, params and escaped ivars" do
    context, io = build_context("GET", "/posts/1")
    run_action(context, {"id" => "1"})
    raw = io.to_s
    raw.should contain("200")
    raw.should contain("<layout><h1>Hello &lt;Post&gt;</h1><span>id=1</span>")
    raw.should contain("</layout>")
    raw.should contain("Content-Type: text/html")
  end

  it "merges query params" do
    context, io = build_context("GET", "/posts/7", "id=7&format=json")
    run_action(context, {"id" => "7"})
    io.to_s.should contain("id=7")
  end

  it "render plain:" do
    context, io = build_context("GET", "/")
    run_action(context, action: "plain")
    io.to_s.should contain("just text")
    context.response.headers["Content-Type"].should contain("text/plain")
  end

  it "redirect_to" do
    context, io = build_context("GET", "/")
    run_action(context, action: "redirect")
    context.response.status_code.should eq(302)
    context.response.headers["Location"].should eq("/somewhere")
  end

  it "raises RoutingError for unknown action" do
    context, io = build_context("GET", "/")
    expect_raises ActionController::RoutingError do
      run_action(context, action: "nope")
    end
  end

  it "turbo-stream Accept without .turbo_stream.erb falls back to the HTML template" do
    # Turbo redirect-follow GET несёт Accept с обоими форматами; Rails без
    # turbo_stream-шаблона рендерит HTML (lookup по списку форматов), не 404.
    context, io = build_context("GET", "/posts/1",
      accept: "text/vnd.turbo-stream.html, text/html, application/xhtml+xml")
    run_action(context, {"id" => "1"})
    raw = io.to_s
    raw.should contain("200")
    raw.should contain("Content-Type: text/html")
    raw.should contain("<layout><h1>")
  end

  it "renders .turbo_stream.erb without layout for turbo-stream Accept when present" do
    context, io = build_context("GET", "/", accept: "text/vnd.turbo-stream.html, text/html")
    run_action(context, action: "streamed")
    context.response.headers["Content-Type"].should contain("text/vnd.turbo-stream.html")
    io.to_s.should contain("TS body")
    io.to_s.should_not contain("<layout>")
  end

  it "raises RoutingError for missing template" do
    context, io = build_context("GET", "/")
    expect_raises ActionController::RoutingError, /Missing template/ do
      run_action(context, action: "no_template")
    end
  end
end
