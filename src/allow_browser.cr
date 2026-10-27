# ActionController::AllowBrowser — port of actionpack 8.1
# lib/action_controller/metal/allow_browser.rb.
#
# `allow_browser versions:` registers a before-filter (so `only:` /
# `except:` / `if:` / `unless:` work through the normal filter
# machinery). A blocked browser runs the handler: `block: :method`
# (controller method name), the macro's own block, or the default —
# public/406-unsupported-browser.html (cwd-relative) with status 406,
# like Rails' render file: + status: :not_acceptable.
#
# Browser/version/bot detection is a port of the useragent gem
# (gshutler/useragent 0.16.x) subset allow_browser needs: the UA is
# split into product/version/comment segments, then a browser is picked
# in Browsers::ALL order — Edge (legacy "Edge" product), Internet
# Explorer, Opera (first "Opera" / trailing "OPR"), Vivaldi, Chrome
# (incl. CriOS), WebKit/Safari, Gecko (Firefox & friends). WeChat and
# the media-player/iTunes classes fall through to their first product,
# same as the gem's Browsers::Base fallback. The WebKit build-version
# map (Safari < 3) is not ported: those UAs report no version and are
# allowed, as Rails allows agents without a reported version.
#
# Deviation from the gem: none for `blocked?` semantics — version
# reported + guarded browser + version below minimum + not a bot.

module ActionController
  module AllowBrowser
    # Compile-time counter for unique generated filter method names.
    BLOCKS = [] of Nil

    # Rails BrowserBlocker::SETS[:modern].
    MODERN = {safari: 17.2, chrome: 120, firefox: 121, opera: 106, ie: false}

    DEFAULT_BLOCKED_HTML = <<-HTML
      <!DOCTYPE html>
      <html>
        <head>
          <title>Unsupported browser</title>
        </head>
        <body>
          <h1>Upgrade to a supported web browser</h1>
          <p>You are using an unsupported web browser. Please update your browser to continue.</p>
        </body>
      </html>
      HTML

    # Port of the useragent gem's UserAgent/Browsers detection subset.
    class UserAgent
      # useragent gem MATCHER: optional opening quotes, product,
      # optional version, then " (comment)" or ",gzip(gfe)".
      SEGMENT = /\A['"]*([^\/\s]+)\/?([^\s,]*)(?:[ ]\(([^\)]*)\)|,gzip\(gfe\))?/

      private struct Segment
        getter product : String
        getter version : String
        getter comment : Array(String)

        def initialize(@product, version : String?, comment : String?)
          @version = version || ""
          @comment = comment ? comment.split("; ") : [] of String
        end
      end

      getter segments = [] of Segment
      getter browser = ""
      getter version = ""

      def self.parse(string : String) : self
        agent = new
        rest = string
        while !rest.empty? && (match = rest.match(SEGMENT))
          product = match[1]?
          break if product.nil? || product.empty?
          agent.segments << Segment.new(product, match[2]?, match[3]?)
          rest = rest[match[0].size..].strip
        end
        agent.detect
        agent
      end

      def initialize
      end

      protected def detect : Nil
        first = segments.first?
        return if first.nil?
        # Chrome/WebKit override #application: first agent with a
        # non-empty comment.
        app = segments.find { |s| !s.comment.empty? } || first
        last = segments.last

        @browser, @version =
          if last.product == "Edge"
            # Legacy EdgeHTML: declares a trailing "Edge/x.y" product.
            {"Edge", last.version}
          elsif first.comment[1]?.try(&.includes?("MSIE")) ||
                first.comment.join("; ").matches?(/Trident.+rv:/)
            version = first.comment.join("; ")[/(?:MSIE\s|rv:)([\d\.]+)/, 1]?
            {"Internet Explorer", version || ""}
          elsif first.product == "Opera" || app.product == "Opera" ||
                last.product == "OPR"
            {"Opera", product_version("Version") || product_version("OPR") || first.version}
          elsif product?("Vivaldi")
            {"Vivaldi", last.version}
          elsif product?("Chrome") || product?("CriOS")
            {"Chrome", product_version("CriOS") || product_version("Chrome") || ""}
          elsif segments.any? { |s| s.product.matches?(/applewebkit/i) }
            android = app.comment.any? { |c| c.matches?(/Android/) }
            blackberry = app.comment[0]? == "BB10" ||
                         app.comment[0]?.try(&.starts_with?("BlackBerry")) || false
            name = android ? "Android" : blackberry ? "BlackBerry" : "Safari"
            version = product_version("Version")
            if version.nil? && name == "Safari" && (ios = ios_comment_version)
              version = ios
            end
            {name, version || ""}
          elsif first.product == "Mozilla"
            # Gecko family (useragent gem GeckoBrowsers order).
            gecko = {"PaleMoon", "Firefox", "Camino", "Iceweasel", "Seamonkey"}.find { |n| product?(n) }
            gecko ? {gecko, product_version(gecko) || first.version} : {first.product, first.version}
          else
            {first.product, first.version}
          end
      end

      # useragent gem user_agent_version_reported?: a UA with no
      # reported version is never blocked.
      def version_reported? : Bool
        !version.empty?
      end

      # useragent gem Browsers::Base#bot?: no application, a comment
      # part matching /bot/i, the Chrome-Lighthouse product, or a first
      # product containing "bot".
      def bot? : Bool
        first = segments.first?
        return true if first.nil?
        return true if segments.any? { |s| s.comment.any? { |c| c.matches?(/bot/i) } }
        return true if product?("Chrome-Lighthouse")
        first.product.includes?("bot")
      end

      # Dot-separated numeric comparison (useragent gem Version#to_a
      # <=>: [120] < [120, 0, 0, 0], so Chrome "120.0.0.0" clears a
      # minimum of 120).
      def self.version_lt(a : String, b : String) : Bool
        va = a.split('.').map { |part| part.to_i? || 0 }
        vb = b.split('.').map { |part| part.to_i? || 0 }
        va < vb
      end

      private def product?(name : String) : Bool
        segments.any? { |s| s.product.downcase == name.downcase }
      end

      private def product_version(name : String) : String?
        segments.each do |s|
          next unless s.product.downcase == name.downcase
          return s.version unless s.version.empty?
        end
        nil
      end

      # iOS Safari without a Version/ product reports its OS version
      # ("CPU iPhone OS 17_2 like Mac OS X" → "17.2").
      private def ios_comment_version : String?
        segments.each do |s|
          s.comment.each do |c|
            if (match = c.match(/(?:iPhone|CPU) OS ([\d_]+)/))
              return match[1].tr("_", ".")
            end
          end
        end
        nil
      end
    end

    # Rails BrowserBlocker: blocked? = version reported + browser in
    # the versions hash (guarded) + version below the minimum (a
    # `false` minimum blocks every version) + not a bot.
    class BrowserBlocker
      def initialize(@minimums : Hash(String, String?))
      end

      def blocked?(agent : UserAgent) : Bool
        return false unless agent.version_reported?
        name = agent.browser.downcase
        name = "ie" if name == "internet explorer"
        return false unless @minimums.has_key?(name)
        return false if agent.bot?
        minimum = @minimums[name]
        minimum.nil? ? true : UserAgent.version_lt(agent.version, minimum)
      end
    end

    # allow_browser versions: { safari: 17.2, chrome: 120 }, only: :show
    # allow_browser versions: :modern, block: :handle_outdated_browser
    # allow_browser versions: :modern do ... end
    #
    # Deviation from Rails: `block: -> { ... }` lambdas can't be
    # instance_exec'd in Crystal (see RateLimiting) — `block:` takes a
    # controller method name, or pass the handler as the macro's own
    # block.
    macro allow_browser(versions, block = nil, **opts, &handler)
      {% unknown_opts = opts.keys.reject { |k| ["only", "except", "if", "unless"].includes?(k.id.stringify) } %}
      {% unless unknown_opts.empty? %}
        {% raise "allow_browser: unknown option(s) #{unknown_opts.join(", ")} (supported: only:, except:, if:, unless:, block:)" %}
      {% end %}

      {% if versions.is_a?(SymbolLiteral) %}
        {% if versions.stringify.gsub(/^:/, "") == "modern" %}
          {% expanded = MODERN %}
        {% else %}
          {% raise "allow_browser: unknown versions set #{versions} (supported: :modern)" %}
        {% end %}
      {% elsif versions.is_a?(NamedTupleLiteral) %}
        {% expanded = versions %}
      {% else %}
        {% expanded = versions.resolve %}
        {% unless expanded.is_a?(NamedTupleLiteral) %}
          {% raise "allow_browser: versions must be :modern, a named tuple like { safari: 17.2, chrome: 120 } or such a constant" %}
        {% end %}
      {% end %}

      {% fid = "__allow_browser_#{ActionController::AllowBrowser::BLOCKS.size}".id %}
      {% ActionController::AllowBrowser::BLOCKS << nil %}

      def {{ fid }} : Nil
        ua = request.headers["User-Agent"]?
        return if ua.nil? || ua.empty?
        agent = ::ActionController::AllowBrowser::UserAgent.parse(ua)
        minimums = {} of String => String?
        {% for key, value in expanded %}
          {% if value.stringify == "false" %}
            minimums[{{ key.stringify }}] = nil
          {% else %}
            minimums[{{ key.stringify }}] = {{ value.stringify }}
          {% end %}
        {% end %}
        if ::ActionController::AllowBrowser::BrowserBlocker.new(minimums).blocked?(agent)
          payload = {
            "request"  => request.path,
            "versions" => minimums.to_s,
          } of String => ActiveSupport::Any
          ActiveSupport::Notifications.instrument("browser_block.action_controller", payload) do
            {% if block %}
              {{ block.id }}
            {% elsif handler %}
              {{ handler.body }}
            {% else %}
              __allow_browser_default_block
            {% end %}
          end
        end
      end

      {% ActionController::FILTERS << { @type, fid.symbolize, opts } %}
    end

    # Rails default block: render file: public/406-unsupported-browser.html,
    # layout: false, status: :not_acceptable.
    private def __allow_browser_default_block : Nil
      @performed = true
      response.status_code = 406
      response.headers["Content-Type"] = "text/html; charset=utf-8"
      if File.exists?("public/406-unsupported-browser.html")
        response.print File.read("public/406-unsupported-browser.html")
      else
        response.print ::ActionController::AllowBrowser::DEFAULT_BLOCKED_HTML
      end
    end
  end

  class Base
    include AllowBrowser
  end
end
