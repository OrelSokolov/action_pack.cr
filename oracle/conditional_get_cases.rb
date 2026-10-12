# Oracle: Rails 8.1.4 ActionController::ConditionalGet (fresh_when /
# stale?) — HTTP conditional caching (ETag / Last-Modified / 304).
# Runs inside the throwaway rails app (devise.cr/tmp/http_app, 8.1.4)
# with a temporary FwController (app/controllers/fw_controller.rb).
#   ruby conditional_get_cases.rb > conditional_get_expected.yml
require_relative "../../devise.cr/tmp/http_app/config/environment"

def emit(id, value)
  puts "#{id}\t#{value}"
end

session = ActionDispatch::Integration::Session.new(Rails.application)

def fw(session, path, headers = {})
  session.get path, headers: headers
  [session.response.status, session.response.headers, session.response.body]
end

# --- etag (weak) ------------------------------------------------------
status, headers, body = fw(session, "/fw/etag")
etag = headers["ETag"]
emit("fw_etag_status", status.inspect)
emit("fw_etag_header_format", etag.sub(/[0-9a-f]+/, "HEX").inspect)
emit("fw_etag_body", body.inspect)

status, headers, body = fw(session, "/fw/etag", {"HTTP_IF_NONE_MATCH" => etag})
emit("fw_etag_match_304", status.inspect)
emit("fw_etag_match_body", body.inspect)
emit("fw_etag_match_cc", headers["Cache-Control"].inspect)

status, = fw(session, "/fw/etag", {"HTTP_IF_NONE_MATCH" => %{W/"other"}})
emit("fw_etag_miss_200", status.inspect)

# --- strong etag ------------------------------------------------------
_, headers, = fw(session, "/fw/strong")
emit("fw_strong_header_format", headers["ETag"].sub(/[0-9a-f]+/, "HEX").inspect)

# --- last_modified ----------------------------------------------------
_, headers, = fw(session, "/fw/lm")
lm = headers["Last-Modified"]
emit("fw_lm_header", lm.inspect)
status, = fw(session, "/fw/lm", {"HTTP_IF_MODIFIED_SINCE" => lm})
emit("fw_lm_match_304", status.inspect)
status, = fw(session, "/fw/lm", {"HTTP_IF_MODIFIED_SINCE" => "Mon, 29 Dec 2025 12:00:00 GMT"})
emit("fw_lm_older_200", status.inspect)
status, = fw(session, "/fw/lm", {"HTTP_IF_MODIFIED_SINCE" => "Thu, 01 Jan 2026 12:00:01 GMT"})
emit("fw_lm_newer_304", status.inspect)

# --- etag + last_modified + public -------------------------------------
status, headers, = fw(session, "/fw/both")
etag = headers["ETag"]
lm = headers["Last-Modified"]
emit("fw_both_cache_control", headers["Cache-Control"].inspect)
status, = fw(session, "/fw/both", {"HTTP_IF_NONE_MATCH" => etag,
                                   "HTTP_IF_MODIFIED_SINCE" => "Mon, 29 Dec 2025 12:00:00 GMT"})
emit("fw_both_inm_wins_304", status.inspect)
status, = fw(session, "/fw/both", {"HTTP_IF_NONE_MATCH" => %{W/"other"},
                                   "HTTP_IF_MODIFIED_SINCE" => lm})
emit("fw_both_inm_miss_200", status.inspect)

# --- stale? ------------------------------------------------------------
status, headers, body = fw(session, "/fw/stale_etag")
emit("fw_stale_first_body", body.inspect)
etag = headers["ETag"]
status, _, body = fw(session, "/fw/stale_etag", {"HTTP_IF_NONE_MATCH" => etag})
emit("fw_stale_fresh_304", status.inspect)
emit("fw_stale_fresh_body", body.inspect)
