# OpenAPI codegen spec (Iteration 10): the document built from the
# route table + typed_params registry must be structurally correct and
# must validate against the REAL openapi3_parser gem (reverse check via
# oracle/verify_openapi.rb, the repo's verify_* pattern).

require "spec"
require "json"
require "../src/action_pack_cr"

class ApplicationController < ActionController::Base
end

class ApisController < ApplicationController
  typed_params(:create) do
    required :title, String, min_size: 3, max_size: 5
    required :age, Int32, gteq: 2, lteq: 10
    optional :admin, Bool?
    required :tags, Array(String), min_size: 1
    required :author do
      required :name, String
      optional :bio, String?, max_size: 10
    end
  end

  typed_params(:index) do
    optional :q, String?
    optional :limit, Int32, lteq: 100
  end
end

def openapi_routes : CRails::Routes::RouteSet
  set = CRails::Routes::RouteSet.new
  set.draw do
    resources "apis"
    openapi "/openapi.json"
  end
  set
end

def openapi_doc : JSON::Any
  CRails::OpenAPI.routes = openapi_routes
  JSON.parse(CRails::OpenAPI.document(title: "Test API", version: "2.0"))
end

describe "CRails::OpenAPI document" do
  doc = openapi_doc

  it "has the envelope" do
    doc["openapi"].should eq("3.0.3")
    doc["info"]["title"].should eq("Test API")
    doc["info"]["version"].should eq("2.0")
  end

  it "maps routes to paths and operations" do
    paths = doc["paths"].as_h.keys
    paths.should contain("/apis")
    paths.should contain("/apis/{id}")
    doc["paths"]["/apis"]["get"]["operationId"].should eq("apis_index")
    doc["paths"]["/apis"]["post"]["operationId"].should eq("apis_create")
    doc["paths"]["/apis/{id}"]["get"]["tags"].should eq(JSON::Any.new(["apis"].map { |s| JSON::Any.new(s) }))
    doc["paths"]["/openapi.json"]["get"]["operationId"].should eq("c_rails_open_api_show")
  end

  it "declares path parameters" do
    params = doc["paths"]["/apis/{id}"]["get"]["parameters"].as_a
    params.size.should eq(1)
    params[0]["name"].should eq("id")
    params[0]["in"].should eq("path")
    params[0]["required"].should eq(true)
    params[0]["schema"]["type"].should eq("string")
  end

  it "builds the requestBody JSON Schema from typed params" do
    body = doc["paths"]["/apis"]["post"]["requestBody"]
    body["required"].should eq(true)
    schema = body["content"]["application/json"]["schema"]
    schema["type"].should eq("object")
    schema["required"].should eq(JSON::Any.new(["title", "age", "tags", "author"].map { |s| JSON::Any.new(s) }))

    title = schema["properties"]["title"]
    title["type"].should eq("string")
    title["minLength"].should eq(3)
    title["maxLength"].should eq(5)

    age = schema["properties"]["age"]
    age["type"].should eq("integer")
    age["minimum"].should eq(2)
    age["maximum"].should eq(10)

    schema["properties"]["admin"]["type"].should eq("boolean")
    schema["properties"]["admin"]["nullable"].should eq(true)

    tags = schema["properties"]["tags"]
    tags["type"].should eq("array")
    tags["items"]["type"].should eq("string")
    tags["minItems"].should eq(1)

    author = schema["properties"]["author"]
    author["type"].should eq("object")
    author["required"].should eq(JSON::Any.new(["name"].map { |s| JSON::Any.new(s) }))
    author["properties"]["bio"]["nullable"].should eq(true)
    author["properties"]["bio"]["maxLength"].should eq(10)
  end

  it "builds query parameters for GET actions" do
    params = doc["paths"]["/apis"]["get"]["parameters"].as_a
    q = params.find { |p| p["name"] == "q" }.not_nil!
    q["in"].should eq("query")
    q["required"].should eq(false)
    q["schema"]["type"].should eq("string")
    q["schema"]["nullable"].should eq(true)
    limit = params.find { |p| p["name"] == "limit" }.not_nil!
    limit["schema"]["maximum"].should eq(100)
  end

  it "validates against the real openapi3_parser gem" do
    path = "#{__DIR__}/../tmp/openapi_verify.json"
    File.write(path, CRails::OpenAPI.document(title: "Test API", version: "2.0"))
    gem_home = "#{ENV["HOME"]}/.gem/ruby/3.4.0"
    if Dir.exists?(gem_home)
      status = Process.run(
        "ruby", [File.expand_path("../oracle/verify_openapi.rb", __DIR__), path],
        env: {"GEM_PATH" => gem_home},
        output: output = IO::Memory.new)
      output.to_s.strip.should eq("OK")
      status.success?.should be_true
    else
      pending! "openapi3_parser not installed (#{gem_home})"
    end
  end

  it "is served by the built-in controller" do
    io = IO::Memory.new
    response = HTTP::Server::Response.new(io)
    request = HTTP::Request.new("GET", "/openapi.json")
    context = HTTP::Server::Context.new(request, response)
    controller = CRails::OpenApiController.new(context)
    controller.__set_params({} of String => String)
    controller.show
    response.close
    body = io.to_s.split("\r\n\r\n", 2).last
    parsed = JSON.parse(body)
    parsed["openapi"].should eq("3.0.3")
    response.headers["Content-Type"].should contain("application/json")
  end
end
