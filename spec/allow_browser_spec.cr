# allow_browser: useragent-gem detection port + filter integration.

require "spec"
require "http"
require "../src/action_pack_cr"

private def ua(string : String)
  ActionController::AllowBrowser::UserAgent.parse(string)
end

describe "AllowBrowser::UserAgent" do
  it "detects Safari with a Version/ product" do
    agent = ua("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15")
    agent.browser.should eq("Safari")
    agent.version.should eq("17.1")
    agent.bot?.should be_false
  end

  it "detects mobile Safari from the iOS comment" do
    agent = ua("Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1")
    agent.browser.should eq("Safari")
    agent.version.should eq("17.2")
  end

  it "detects Chrome (multi-part version)" do
    agent = ua("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.6045.105 Safari/537.36")
    agent.browser.should eq("Chrome")
    agent.version.should eq("119.0.6045.105")
  end

  it "detects Chrome on iOS via CriOS" do
    agent = ua("Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/119.0.6045.109 Mobile/15E148 Safari/604.1")
    agent.browser.should eq("Chrome")
    agent.version.should eq("119.0.6045.109")
  end

  it "detects modern Edge as Chrome (Edg product is not legacy Edge)" do
    agent = ua("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0")
    agent.browser.should eq("Chrome")
    agent.version.should eq("120.0.0.0")
  end

  it "detects legacy Edge from the trailing Edge product" do
    agent = ua("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edge/120.0.0.0")
    agent.browser.should eq("Edge")
    agent.version.should eq("120.0.0.0")
  end

  it "detects Firefox" do
    agent = ua("Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0")
    agent.browser.should eq("Firefox")
    agent.version.should eq("121.0")
  end

  it "detects Opera via the trailing OPR product" do
    agent = ua("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36 OPR/104.0.0.0")
    agent.browser.should eq("Opera")
    agent.version.should eq("104.0.0.0")
  end

  it "detects old Opera from the Version product" do
    agent = ua("Opera/9.80 (Windows NT 6.1; WOW64) Presto/2.12.388 Version/12.16")
    agent.browser.should eq("Opera")
    agent.version.should eq("12.16")
  end

  it "detects Internet Explorer via MSIE" do
    agent = ua("Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)")
    agent.browser.should eq("Internet Explorer")
    agent.version.should eq("9.0")
  end

  it "detects Internet Explorer 11 via Trident+rv" do
    agent = ua("Mozilla/5.0 (Windows NT 6.3; Trident/7.0; rv:11.0) like Gecko")
    agent.browser.should eq("Internet Explorer")
    agent.version.should eq("11.0")
  end

  it "flags bots by comment, product name and Lighthouse" do
    ua("Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)").bot?.should be_true
    ua("Mozilla/5.0 (compatible; SemrushBot/7~bl; +http://www.semrush.com/bot.html)").bot?.should be_true
    ua("Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome-Lighthouse/119.0.6045.105 Mobile Safari/537.36").bot?.should be_true
    ua("Googlebot/2.1 (+http://www.google.com/bot.html)").bot?.should be_true
  end
end

describe "AllowBrowser::BrowserBlocker" do
  it "blocks below-minimum browsers" do
    minimums = {"safari" => "17.2", "chrome" => "120", "firefox" => "121", "opera" => "104", "ie" => nil} of String => String?
    blocker = ActionController::AllowBrowser::BrowserBlocker.new(minimums)

    blocker.blocked?(ua("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15")).should be_true
    blocker.blocked?(ua("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15")).should be_false
    blocker.blocked?(ua("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")).should be_false
    blocker.blocked?(ua("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.9 Safari/537.36")).should be_true
    blocker.blocked?(ua("Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)")).should be_true
    # Bots and unguarded browsers pass.
    blocker.blocked?(ua("Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)")).should be_false
    blocker.blocked?(ua("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0")).should be_false
  end
end

# --- filter integration ---------------------------------------------------

class BrowserGuardedController < ActionController::Base
  VERSIONS = {safari: 17.2, chrome: 120, firefox: 121, opera: 104, ie: false}

  allow_browser versions: VERSIONS do
    render plain: "blocked"
  end

  def index
    render plain: "welcome"
  end
end

class BrowserModernController < ActionController::Base
  allow_browser versions: :modern, block: :custom_block, only: [:show]

  def index
    render plain: "index"
  end

  def show
    render plain: "show"
  end

  private def custom_block
    render plain: "custom", status: 406
  end
end

class BrowserDefaultController < ActionController::Base
  allow_browser versions: :modern

  def index
    render plain: "index"
  end
end

private def browser_context(user_agent : String?) : {HTTP::Server::Context, IO::Memory}
  headers = HTTP::Headers.new
  headers["User-Agent"] = user_agent if user_agent
  io = IO::Memory.new
  {HTTP::Server::Context.new(HTTP::Request.new("GET", "/", headers), HTTP::Server::Response.new(io)), io}
end

private def run_browser_action(klass, action : String, user_agent : String?)
  context, io = browser_context(user_agent)
  controller = klass.new(context)
  controller.__set_params({} of String => String)
  controller.__run_action(action)
  context.response.close
  {context, io}
end

SAFARI_17_1 = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15"
SAFARI_17_2 = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"

describe "allow_browser" do
  it "blocks an outdated browser via the macro block" do
    context, io = run_browser_action(BrowserGuardedController, "index", SAFARI_17_1)
    context.response.status_code.should eq(200)
    io.to_s.should contain("blocked")
  end

  it "allows a current browser to run the action" do
    context, io = run_browser_action(BrowserGuardedController, "index", SAFARI_17_2)
    context.response.status_code.should eq(200)
    io.to_s.should contain("welcome")
    io.to_s.should_not contain("blocked")
  end

  it "allows requests without a user agent" do
    context, io = run_browser_action(BrowserGuardedController, "index", nil)
    context.response.status_code.should eq(200)
    io.to_s.should contain("welcome")
  end

  it "serves the default 406 page when no block is given" do
    context, io = run_browser_action(BrowserDefaultController, "index", SAFARI_17_1)
    context.response.status_code.should eq(406)
    io.to_s.should contain("Unsupported browser")
  end

  it "runs the block: handler method and honors only:" do
    context, io = run_browser_action(BrowserModernController, "show", SAFARI_17_1)
    context.response.status_code.should eq(406)
    io.to_s.should contain("custom")
  end

  it "keeps unlisted actions unguarded with only:" do
    context, io = run_browser_action(BrowserModernController, "index", SAFARI_17_1)
    context.response.status_code.should eq(200)
    io.to_s.should contain("index")
  end
end

