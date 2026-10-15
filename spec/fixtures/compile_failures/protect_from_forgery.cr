require "../../../src/action_pack_cr"

# Regression for the 0.1.3 guard itself.
class FailingForgeryController < ActionController::Base
  protect_from_forgery with: :exception, foo: true

  def show
    render plain: "ok"
  end
end
