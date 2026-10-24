require "spec"
require "http"
require "../src/action_pack_cr"

# Helper wiring: convention auto-include (XController → XHelper/XHelpers),
# explicit `helper :sym` (Rails API) and the `helper_method` annotation.
# Controllers render plain text, so no template fixtures are involved.

module ConventionalsHelpers
  include ActionController::Helper

  def convention_marker : String
    "from-convention"
  end
end

module LegacyHelpers
  include ActionController::Helper

  def legacy_marker : String
    "from-explicit-helper"
  end
end

abstract class WiringBaseController < ActionController::Base
end

class ConventionalsController < WiringBaseController
  def show
    render plain: convention_marker
  end
end

class OddThingsController < WiringBaseController
  helper :legacy

  def show
    render plain: legacy_marker
  end
end

class ExposedController < WiringBaseController
  helper_method :exposed_setting

  def show
    render plain: exposed_setting
  end

  def exposed_setting : String
    "exposed"
  end
end

private def run_wiring(klass, context)
  controller = klass.new(context)
  controller.__run_action("show")
  context.response.close
end

private def wiring_response(klass) : String
  io = IO::Memory.new
  run_wiring(klass, HTTP::Server::Context.new(
    HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(io)))
  io.to_s
end

describe "helper wiring" do
  it "auto-includes the conventional registered helper (plural variant)" do
    wiring_response(ConventionalsController).should contain("from-convention")
  end

  it "includes explicitly declared helper :sym" do
    wiring_response(OddThingsController).should contain("from-explicit-helper")
  end

  it "helper_method validates and keeps controller methods callable" do
    wiring_response(ExposedController).should contain("exposed")
  end
end
