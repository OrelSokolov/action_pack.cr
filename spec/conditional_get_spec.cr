# Oracle spec: ActionController::ConditionalGet против
# oracle/conditional_get_expected.yml (rails 8.1.4). Те же case-ID,
# те же ожидания (ruby-inspect формат). Контроллеры зеркалят
# temporary FwController из оракул-скрипта.

require "spec"
require "http"
require "../src/action_pack_cr"

CG_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/conditional_get_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

abstract class ApplicationController < ActionController::Base
end

# Зеркало temporary FwController оракула (fw_controller.rb).
class FwController < ApplicationController
  def etag
    fresh_when(etag: "v1")
    render plain: "etag-body" unless @performed
  end

  def strong
    fresh_when(strong_etag: "v1")
    render plain: "strong-body" unless @performed
  end

  def lm
    fresh_when(last_modified: Time.utc(2026, 1, 1, 12, 0, 0))
    render plain: "lm-body" unless @performed
  end

  def both
    fresh_when(etag: "v1", last_modified: Time.utc(2026, 1, 1, 12, 0, 0),
               public: true)
    render plain: "both-body" unless @performed
  end

  def stale_etag
    if stale?(etag: "v1")
      render plain: "stale-body"
    end
  end
end

private def dispatch(action : String, if_none_match : String? = nil,
                     if_modified_since : String? = nil) : {HTTP::Server::Context, String}
  headers = HTTP::Headers.new
  headers["If-None-Match"] = if_none_match if if_none_match
  headers["If-Modified-Since"] = if_modified_since if if_modified_since
  request = HTTP::Request.new("GET", "/", headers)
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  controller = FwController.new(context)
  controller.__set_params({} of String => String)
  controller.__run_action(action)
  context.response.close
  {context, io.to_s}
end

# Тело ответа: raw — весь HTTP-ответ (статус/заголовки + тело).
private def body(raw : String) : String
  parts = raw.split("\r\n\r\n", 2)
  parts[1]? || ""
end

describe "ActionController::ConditionalGet (rails 8.1.4 oracle)" do
  it "fw_etag_status / body / hex / cc_200" do
    ctx, raw = dispatch("etag")
    ctx.response.status_code.inspect.should eq CG_EXPECTED["fw_etag_status"]
    ctx.response.headers["ETag"]?.try(&.sub(/[0-9a-f]+/, "HEX")).inspect
      .should eq CG_EXPECTED["fw_etag_header_format"]
    body(raw).inspect.should eq CG_EXPECTED["fw_etag_body"]
    ctx.response.headers["Cache-Control"]?.inspect
      .should eq CG_EXPECTED["fw_etag_cc_200"]
    # точное значение хеша: sha256("v1")[0,32]
    ctx.response.headers["ETag"]?.inspect.should eq CG_EXPECTED["fw_etag_hex"]
  end

  it "fw_etag_match_304 / body / cc" do
    first, _raw0 = dispatch("etag")
    etag = first.response.headers["ETag"].not_nil!
    ctx, raw = dispatch("etag", if_none_match: etag)
    ctx.response.status_code.inspect.should eq CG_EXPECTED["fw_etag_match_304"]
    body(raw).inspect.should eq CG_EXPECTED["fw_etag_match_body"]
    ctx.response.headers["Cache-Control"]?.inspect
      .should eq CG_EXPECTED["fw_etag_match_cc"]
  end

  it "fw_etag_miss_200" do
    ctx, raw = dispatch("etag", if_none_match: %(W/"other"))
    ctx.response.status_code.inspect.should eq CG_EXPECTED["fw_etag_miss_200"]
  end

  it "fw_strong_header_format" do
    ctx, raw = dispatch("strong")
    ctx.response.headers["ETag"]?.try(&.sub(/[0-9a-f]+/, "HEX")).inspect
      .should eq CG_EXPECTED["fw_strong_header_format"]
  end

  it "fw_lm_header / match_304 / older_200 / newer_304" do
    ctx, raw = dispatch("lm")
    lm = ctx.response.headers["Last-Modified"].not_nil!
    lm.inspect.should eq CG_EXPECTED["fw_lm_header"]

    ctx, raw = dispatch("lm", if_modified_since: lm)
    ctx.response.status_code.inspect.should eq CG_EXPECTED["fw_lm_match_304"]

    ctx, raw = dispatch("lm", if_modified_since: "Mon, 29 Dec 2025 12:00:00 GMT")
    ctx.response.status_code.inspect.should eq CG_EXPECTED["fw_lm_older_200"]

    ctx, raw = dispatch("lm", if_modified_since: "Thu, 01 Jan 2026 12:00:01 GMT")
    ctx.response.status_code.inspect.should eq CG_EXPECTED["fw_lm_newer_304"]
  end

  it "fw_both_cache_control / inm_wins_304 / inm_miss_200" do
    ctx, raw = dispatch("both")
    etag = ctx.response.headers["ETag"].not_nil!
    lm = ctx.response.headers["Last-Modified"].not_nil!
    ctx.response.headers["Cache-Control"]?.inspect
      .should eq CG_EXPECTED["fw_both_cache_control"]

    ctx, raw = dispatch("both", if_none_match: etag,
                   if_modified_since: "Mon, 29 Dec 2025 12:00:00 GMT")
    ctx.response.status_code.inspect.should eq CG_EXPECTED["fw_both_inm_wins_304"]

    ctx, raw = dispatch("both", if_none_match: %(W/"other"), if_modified_since: lm)
    ctx.response.status_code.inspect.should eq CG_EXPECTED["fw_both_inm_miss_200"]
  end

  it "fw_stale_first_body / fresh_304 / fresh_body" do
    ctx, raw = dispatch("stale_etag")
    body(raw).inspect.should eq CG_EXPECTED["fw_stale_first_body"]
    etag = ctx.response.headers["ETag"].not_nil!

    ctx, raw = dispatch("stale_etag", if_none_match: etag)
    ctx.response.status_code.inspect.should eq CG_EXPECTED["fw_stale_fresh_304"]
    body(raw).inspect.should eq CG_EXPECTED["fw_stale_fresh_body"]
  end

  it "If-None-Match: * matches any etag (gem behavior)" do
    ctx, raw = dispatch("etag", if_none_match: "*")
    ctx.response.status_code.should eq(304)
  end
end
