require "../../../src/action_pack_cr"

# `prepend:` is a valid Rails option that this port does not support —
# it must be a compile error, not silently ignored.
class FailingBeforeActionController < ActionController::Base
  before_action :authenticate, only: [:show], prepend: true

  def show
    render plain: "ok"
  end

  def authenticate
  end
end
