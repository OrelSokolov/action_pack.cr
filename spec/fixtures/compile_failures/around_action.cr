require "../../../src/action_pack_cr"

class FailingAroundActionController < ActionController::Base
  around_action :wrap, only: [:show], prepend: true

  def show
    render plain: "ok"
  end

  def wrap
    yield
  end
end
