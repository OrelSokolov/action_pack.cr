require "../../../src/action_pack_cr"

class FailingRateLimitController < ActionController::Base
  rate_limit to: 5, within: 1.minute, store: :mem_cache, foo: true

  def show
    render plain: "ok"
  end
end
