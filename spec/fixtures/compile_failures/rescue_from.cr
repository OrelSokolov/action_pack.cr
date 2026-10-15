require "../../../src/action_pack_cr"

class FailingRescueFromController < ActionController::Base
  rescue_from KeyError, with: :handle_key, foo: true

  def show
    render plain: "ok"
  end

  def handle_key(ex : KeyError)
    render plain: "handled"
  end
end
