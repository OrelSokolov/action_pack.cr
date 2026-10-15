require "../../../src/action_pack_cr"

# `raise:` is a valid Rails option that this port does not support —
# it must be a compile error, not silently ignored.
class FailingSkipBeforeActionController < ActionController::Base
  before_action :authenticate
  skip_before_action :authenticate, raise: false

  def show
    render plain: "ok"
  end

  def authenticate
  end
end
