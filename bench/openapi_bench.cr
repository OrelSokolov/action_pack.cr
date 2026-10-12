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
CRails::OpenAPI.routes = CRails::Routes::RouteSet.new.tap do |set|
  set.draw do
    resources "apis"
    resources "posts"
    resources "users"
    get "/search", to: "apis#index"
    openapi "/openapi.json"
  end
end
n = 0
t0 = Time.instant
while Time.instant - t0 < 2.seconds
  CRails::OpenAPI.document
  n += 1
end
printf "openapi docs/sec: %.0f (%.1f routes-doc: %d bytes)\n", n / 2.0, (2.0/n)*1e6, CRails::OpenAPI.document.bytesize
