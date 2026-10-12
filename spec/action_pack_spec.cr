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
end

private def build_context(method : String, path : String, query : String? = nil) : Tuple(HTTP::Server::Context, IO::Memory)
  request = HTTP::Request.new(method, path + (query ? "?#{query}" : ""))
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

  it "raises RoutingError for missing template" do
    context, io = build_context("GET", "/")
    expect_raises ActionController::RoutingError, /Missing template/ do
      run_action(context, action: "no_template")
    end
  end
end
