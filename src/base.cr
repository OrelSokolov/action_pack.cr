# ActionController::Base — Iteration 0 slice.
#
# Codegen strategy (no runtime metaprogramming):
# - `macro inherited` registers each controller subclass (TypeNode) in
#   ActionController::REGISTRY at compile time.
# - A top-level `macro finished` hook runs at the end of the program and
#   injects `__run_action` / `__render_view` into every concrete
#   controller, wiring actions to ECR templates via `ECR.embed`.
#
# Views root is taken from CRAILS_VIEWS (compile-time ENV), so specs and
# apps can point it at their own `app/views`. Default: "app/views",
# relative to the directory `crystal build` runs in.

module ActionController
  VERSION = "0.1.0"

  # Opt-out for the implicit-render dedent mode: templates compiled
  # through the implicit action render strip leading whitespace of
  # each line at compile time (flat output from indented sources);
  # a controller whose templates were ported WITH indentation in
  # their output annotates itself to keep the old bytes.
  annotation NoTemplateDedent; end

  # Compile-time registry of controller classes (filled by `inherited`).
  REGISTRY = [] of TypeNode
  # Compile-time registry of before_action filters / rescue handlers
  # (filled by the `before_action` / `rescue_from` macros).
  FILTERS = [] of {TypeNode, Symbol, NamedTuple}
  RESCUERS = [] of {TypeNode, TypeNode, Symbol}
  # Compile-time registry of around_action filters (symbol or generated
  # block method), filled by the `around_action` macro.
  AROUND_FILTERS = [] of {TypeNode, Symbol, NamedTuple}

  class RoutingError < Exception
  end

  class Base
    include ActionView::Helpers
    include ConditionalGet
    include CRails::Routes::UrlHelpers

    attr_reader context : HTTP::Server::Context
    attr_reader params : Parameters

    def initialize(@context : HTTP::Server::Context)
      @params = Parameters.new
      @performed = false
    end

    def request : HTTP::Request
      @context.request
    end

    def response : HTTP::Server::Response
      @context.response
    end

    @cookies : Cookies?
    @session : Session?
    @flash : Flash?

    def cookies : Cookies
      @cookies ||= Cookies.new(@context)
    end

    def session : Session
      @session ||= Session.new(cookies)
    end

    def flash : Flash
      @flash ||= Flash.new(cookies)
    end

    # --- filters ------------------------------------------------------

    # before_action :authenticate, only: [:index] / except: / if: / unless:
    # Unknown keys are a compile error (see protect_from_forgery): a
    # silently ignored option masks a filter that never runs as intended.
    macro before_action(*names, **opts)
      {% unknown_opts = opts.keys.reject { |k| ["only", "except", "if", "unless"].includes?(k.id.stringify) } %}
      {% unless unknown_opts.empty? %}
        {% raise "before_action: unknown option(s) #{unknown_opts.join(", ")} (supported: only:, except:, if:, unless:)" %}
      {% end %}
      {% for name in names %}
        {% ActionController::FILTERS << { @type, name, opts } %}
      {% end %}
    end

    macro skip_before_action(*names, **opts)
      {% unknown_opts = opts.keys.reject { |k| ["only", "except", "if", "unless"].includes?(k.id.stringify) } %}
      {% unless unknown_opts.empty? %}
        {% raise "skip_before_action: unknown option(s) #{unknown_opts.join(", ")} (supported: only:, except:, if:, unless:)" %}
      {% end %}
      {% for name in names %}
        {% skip_name = "__skip_#{name.id}".id %}
        {% ActionController::FILTERS << { @type, skip_name.symbolize, opts } %}
      {% end %}
    end

    # around_action :set_time_zone / around_action only: [:show] do ... end
    # The filter method (or block) receives the action continuation via
    # `yield` and MUST call it.
    macro around_action(*names, **opts, &block)
      {% unknown_opts = opts.keys.reject { |k| ["only", "except", "if", "unless"].includes?(k.id.stringify) } %}
      {% unless unknown_opts.empty? %}
        {% raise "around_action: unknown option(s) #{unknown_opts.join(", ")} (supported: only:, except:, if:, unless:)" %}
      {% end %}
      {% for name in names %}
        {% ActionController::AROUND_FILTERS << { @type, name, opts } %}
      {% end %}
      {% if block %}
        {% method_name = "__around_block_#{ActionController::AROUND_FILTERS.size}".id %}
        def {{ method_name }}(&)
          {{ block.body }}
        end
        {% ActionController::AROUND_FILTERS << { @type, method_name.symbolize, opts } %}
      {% end %}
    end

    # Shared only/except/if/unless condition for filter callbacks;
    # expands to a boolean expression over the `action` method argument.
    # Args arrive pre-extracted (nil when absent) so empty opts never
    # round-trip through generated code.
    macro __callback_condition(only = nil, except = nil, cond_if = nil, cond_unless = nil)
      {% cond = "true" %}
      {% if only %}
        {% cond = "[" + only.map { |a| "\"" + a.stringify.gsub(/^:/, "") + "\"" }.join(", ") + "].includes?(action)" %}
      {% end %}
      {% if except %}
        {% cond = cond + " && ![" + except.map { |a| "\"" + a.stringify.gsub(/^:/, "") + "\"" }.join(", ") + "].includes?(action)" %}
      {% end %}
      {% if cond_if %}
        {% cond = cond + " && " + cond_if.stringify %}
      {% end %}
      {% if cond_unless %}
        {% cond = cond + " && !(" + cond_unless.stringify + ")" %}
      {% end %}
      {{ cond.id }}
    end

    macro rescue_from(exception, **opts)
      {% unknown_opts = opts.keys.reject { |k| ["with"].includes?(k.id.stringify) } %}
      {% unless unknown_opts.empty? %}
        {% raise "rescue_from: unknown option(s) #{unknown_opts.join(", ")} (supported: with:)" %}
      {% end %}
      {% handler = opts[:with] || opts["with"] %}
      {% raise "rescue_from needs a `with:` handler" unless handler %}
      {% ActionController::RESCUERS << { @type, exception, handler } %}
    end

    # --- explicit rendering ---

    def render(json : String, status = nil) : Nil
      @performed = true
      response.status_code = status_code(status) if status
      response.headers["Content-Type"] = "application/json; charset=utf-8"
      __verify_same_origin_request
      response.print json
    end

    # render(template:) — .json.jbuilder-шаблон, скомпилированный на этапе
    # сборки через JbuilderHandler (шард jbuilder.cr; приложение с
    # .json.jbuilder-вьюхами обязано require "jbuilder_cr" — без шарда
    # хендлер не разрешится, как в Rails без гема хендлер не зарегистриро-
    # ван). Путь — полный относительно корня вьюх с расширением или без
    # ("posts/show.json.jbuilder" / "posts/show") либо имя экшена ("show").
    # Только именованный аргумент: перегрузка с позиционной строкой
    # (Rails render "posts/show", formats: :json) конфликтует с
    # render(json : String) — позиционная строка занята телом JSON-ответа
    # (документированное отклонение).
    def render(*, template : String, status = nil) : Nil
      @performed = true
      response.status_code = status_code(status) if status
      response.headers["Content-Type"] = "application/json; charset=utf-8"
      __verify_same_origin_request
      response.print __jb_render_template(template)
    end

    # Rails parity: render не сбрасывает уже назначенный response.status —
    # статус ставится только явным :status (паттерн «response.status = X;
    # render(plain:)» в контроллерах должен отдавать X, а не 200).
    def render(plain : String? = nil, html : String? = nil, status = nil, content_type : String? = nil) : Nil
      @performed = true
      response.status_code = status_code(status) if status
      if body = plain
        response.headers["Content-Type"] = content_type || "text/plain; charset=utf-8"
        __verify_same_origin_request
        response.print body
      elsif body = html
        response.headers["Content-Type"] = content_type || "text/html; charset=utf-8"
        __verify_same_origin_request
        response.print body
      else
        raise ArgumentError.new("render needs plain: or html:")
      end
    end

    def head(status) : Nil
      @performed = true
      response.status_code = status_code(status)
    end

    # --- redirection ---------------------------------------------------

    def redirect_to(location : String, status = 302, notice : String? = nil,
                    alert : String? = nil) : Nil
      flash["notice"] = notice if notice
      flash["alert"] = alert if alert
      @performed = true
      response.status_code = status_code(status)
      response.headers["Location"] = location
      # любой Rails-ответ несёт Content-Type; редирект — text/html
      response.headers["Content-Type"] ||= "text/html; charset=utf-8"
    end

    def redirect_back(fallback_location : String, status = 302) : Nil
      location = request.headers["Referer"]? || fallback_location
      redirect_to(location, status)
    end

    # --- respond_to ----------------------------------------------------

    def respond_to(& : RespondToCollector ->) : Nil
      yield RespondToCollector.new(__request_format)
    end

    class RespondToCollector
      def initialize(@format : String)
      end

      def html(&) : Nil
        yield if @format == "html"
      end

      def json(&) : Nil
        yield if @format == "json"
      end

      # format.turbo_stream без блока — не-op: дефолтный рендер после
      # экшена сам отрендерит #{action}.turbo_stream.erb (см.
      # __default_render), как implicit render в Rails. С блоком —
      # исполняет блок (как html/json).
      def turbo_stream(&) : Nil
        return unless @format == "turbo_stream"
        yield
      end

      def turbo_stream : Nil
      end

      def any(&) : Nil
        yield
      end
    end

    # html unless ?format=json / .json / Accept: application/json;
    # turbo_stream по ?format= / Accept: text/vnd.turbo-stream.html
    private def __request_format : String
      if (fmt = params[:format]?.try(&.to_s)) && {"json", "turbo_stream"}.includes?(fmt)
        return fmt
      end
      if request.headers["Accept"]?.try(&.includes?("text/vnd.turbo-stream.html"))
        return "turbo_stream"
      end
      if request.headers["Accept"]?.try(&.includes?("application/json"))
        return "json"
      end
      "html"
    end

    private def status_code(status : Int32 | Symbol) : Int32
      case status
      when Int32                then status
      when :ok                  then 200
      when :created             then 201
      when :no_content          then 204
      when :moved_permanently   then 301
      when :found               then 302
      when :not_modified        then 304
      when :bad_request         then 400
      when :unauthorized        then 401
      when :forbidden           then 403
      when :not_found           then 404
      when :unprocessable_content then 422
      when :unprocessable_entity then 422 # Rails alias (pre-8 name)
      when :internal_server_error then 500
      else
        raise ArgumentError.new("unsupported status symbol: #{status}")
      end
    end

    # ActionController::Live hook (Iteration 9): перекрывается методом
    # `__live_dispatch` модуля Live — экшен уходит в отдельный fiber,
    # ответ стримится с backpressure. Без include — прямой вызов.
    def __live_dispatch(&) : Nil
      yield
    end

    # --- internal machinery (generated/driver code) ---

    # Rails parity: route params merge with the query/body, and the
    # dispatched controller/action names land in params too (CanCanCan's
    # controller resource reads params["action"]/params["controller"]).
    def __set_params(route_params : Hash(String, String),
                     controller_name : String? = nil, action_name : String? = nil) : Nil
      raw = {} of String => Parameters::Value
      raw["controller"] = controller_name if controller_name
      raw["action"] = action_name if action_name
      route_params.each { |k, v| raw[k] = v }
      query = URI::Params.parse(request.query || "")
      query.each do |key, value|
        raw[key] = value
      end
      __merge_body_params(raw)
      @params = Parameters.from(raw)
    end

    private def __merge_body_params(raw : Hash(String, Parameters::Value)) : Nil
      case request.headers["Content-Type"]?
      when .nil? then nil      when /json/
        body = request.body.try(&.gets_to_end) || ""
        return if body.empty?
        # Re-feed the raw body: controllers that read it themselves
        # (ActionMCP's JSON-RPC envelope) still see the bytes.
        request.body = IO::Memory.new(body)
        # Malformed JSON is not a param-merge concern — the action (or
        # the framework layer reading the raw body) reports it.
        if (json = (JSON.parse(body) rescue nil).try(&.as_h?))
          json.each do |k, v|
            raw_val = v.raw
            raw[k] = case raw_val
            when String then raw_val
            when Int32  then raw_val
            when Int64  then raw_val
            when Float64 then raw_val
            when Bool   then raw_val
            when Nil    then raw_val
            when Array  then raw_val.map { |e| (e.as?(String) || e.to_s).as(Parameters::Scalar) }
            when Hash   then Parameters.from(raw_val)
            else             v.to_s
            end
          end
        end
      when /form-urlencoded/
        body = request.body.try(&.gets_to_end) || ""
        # Re-feed the raw body (как в JSON-ветке): Rack/Rails перематывают
        # input после form-парсинга — экшены, читающие тело сами (bot-POST
        # /rooms/:id/:bot_key/messages с curl-подобным Content-Type),
        # должны видеть байты, а не EOF.
        request.body = IO::Memory.new(body)
        URI::Params.parse(body).each do |k, v|
          __assign_form_key(raw, k, v)
        end
      when /multipart\/form-data/
        # Rails/Rack парсят multipart нативно. Текстовые поля попадают в
        # params теми же nested-ключами, что и в urlencoded; файловые части
        # (Content-Disposition с filename) — как ActionController::UploadedFile
        # (ActionDispatch::Http::UploadedFile). Тело может содержать бинарные
        # байты файлов — только байтовые операции, без regex по контенту
        # (regex на невалидной UTF-8 строке бросает ArgumentError).
        body = request.body.try(&.gets_to_end) || ""
        request.body = IO::Memory.new(body)
        if (boundary = request.headers["Content-Type"][/boundary=([^";]+)/, 1]?)
          delimiter = "--" + boundary.strip('"')
          body.split(delimiter).each do |piece|
            piece = piece.lchop("\r\n").rchop("\r\n")
            next if piece.empty? || piece.starts_with?("--")
            sep = piece.index("\r\n\r\n")
            next unless sep
            headers = piece[0...sep]
            content = piece[(sep + 4)..]
            name = headers[/\bname="([^"]*)"/, 1]?
            next unless name
            if (filename = headers[/\bfilename="([^"]*)"/, 1]?) && !filename.empty?
              # File parts land in params as UploadedFile (Rails semantics);
              # binary body — only byte-safe String ops (see comment above).
              ctype = headers[/content-type:\s*([^\r\n]+)/i, 1]?.try(&.strip) || "application/octet-stream"
              __assign_form_key(raw, name, UploadedFile.new(filename, ctype, content))
            else
              __assign_form_key(raw, name, content)
            end
          end
        end
      end
    end

    # nested form key, Rails-style, arbitrary depth:
    # post[title]=x -> {"post" => {"title" => "x"}}
    # a[b][c]=1 -> {"a" => {"b" => {"c" => "1"}}}
    # Values may be strings (urlencoded/multipart text parts) or
    # UploadedFile (multipart file parts).
    private def __assign_form_key(raw : Hash(String, Parameters::Value), k : String, v : Parameters::Value) : Nil
      if k.includes?('[') && k.ends_with?(']') && (eq = k.index('['))
        keys = k[(eq + 1)...(k.size - 1)].split("][")
        sub = raw[k[0...eq]]?
        unless sub.is_a?(Parameters)
          sub = Parameters.new
          raw[k[0...eq]] = sub
        end
        node = sub.as(Parameters)
        keys[0...-1].each do |ik|
          nxt = node[ik]?
          unless nxt.is_a?(Parameters)
            nxt = Parameters.new
            node[ik] = nxt
          end
          node = nxt.as(Parameters)
        end
        node[keys.last] = v
      else
        raw[k] = v
      end
    end

    # Overwritten by codegen in concrete controllers.
    def __run_action(action : String) : Nil
      raise RoutingError.new("no actions generated for #{self.class} (is it abstract?)")
    end

    # Overwritten by codegen in concrete controllers.
    def __render_view(action : String) : String
      raise RoutingError.new("no templates generated for #{self.class}")
    end

    # Overwritten by codegen in concrete controllers: true для экшенов,
    # у которых есть #{action}.json.jbuilder (implicit render по format=json).
    def __jb_template?(action : String) : Bool
      false
    end

    # Overwritten by codegen in concrete controllers.
    def __render_view_json(action : String) : String
      raise RoutingError.new("no jbuilder templates generated for #{self.class}")
    end

    # Overwritten by codegen in concrete controllers: .json.jbuilder-шаблоны
    # этого контроллера для render(template:) — полный путь ("posts/show.json.jbuilder"
    # / "posts/show") или имя экшена ("show").
    def __jb_render_template(path : String) : String
      raise RoutingError.new("no jbuilder templates generated for #{self.class}")
    end

    def __default_render(action : String) : Nil
      @performed = true
      # Streaming-ответ (ActionController::Live) уже закоммичен записью в
      # response.stream — implicit render не нужен (как в Rails: committed
      # response не рендерится).
      if (stream = response.live_stream?) && stream.committed?
        return
      end
      if __request_format == "json" && __jb_template?(action)
        __verify_same_origin_request
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        response.print __render_view_json(action)
      elsif __request_format == "turbo_stream" && __ts_template?(action)
        # turbo_stream-рендер только при наличии #{action}.turbo_stream.erb:
        # redirect-follow GET от Turbo несёт Accept с обоими форматами
        # (text/vnd.turbo-stream.html, text/html) — Rails без
        # turbo_stream-шаблона рендерит HTML-шаблон (lookup идёт по списку
        # форматов Accept), а не падает. Иначе — HTML-ветка ниже.
        content = __render_view(action, "turbo_stream").to_s
        response.headers["Content-Type"] = "text/vnd.turbo-stream.html; charset=utf-8"
        __verify_same_origin_request
        response.print content
      else
        content = __render_view(action)
        body = __layout? ? __render_layout { content.to_s } : content.to_s
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        __verify_same_origin_request
        response.print body
      end
    end

    # Overridden by RequestForgeryProtection (protect_from_forgery):
    # non-XHR JavaScript responses to GET after a marked request raise
    # InvalidCrossOriginRequest. Runs right before the body is committed,
    # where a raise can still map to 422.
    def __verify_same_origin_request : Nil
    end

    def __layout? : Bool
      {{ (`(test -f #{env("CRAILS_VIEWS") || "app/views"}/layouts/application.html.erb && echo yes) || true`) != "" }}
    end

    macro inherited
      {% ActionController::REGISTRY << @type %}
    end
  end
end

# End-of-program codegen: runs after every controller class is defined.
macro finished
  {% for t in ActionController::REGISTRY %}
    {% unless t.abstract? %}
      {% parts = t.name.split("::") %}
      {% dir = parts.last.underscore.gsub(/_controller$/, "") %}
      {% if parts.size > 1 %}
        {% dir = parts[0...-1].map(&.underscore).join("/") + "/" + dir %}
      {% end %}
      {% root = env("CRAILS_VIEWS") || "app/views" %}
      # Callback method names registered for this controller (its own +
      # inherited): excluded from the action set — around filters take a
      # block and must never be dispatched as actions.
      {% callback_names = [] of String %}
      {% for f in ActionController::FILTERS %}
        {% if f[0] == t || t.ancestors.includes?(f[0]) %}
          {% callback_names << f[1].stringify.gsub(/^:/, "") %}
        {% end %}
      {% end %}
      {% for f in ActionController::AROUND_FILTERS %}
        {% if f[0] == t || t.ancestors.includes?(f[0]) %}
          {% callback_names << f[1].stringify.gsub(/^:/, "") %}
        {% end %}
      {% end %}
      {% for r in ActionController::RESCUERS %}
        {% if r[0] == t || t.ancestors.includes?(r[0]) %}
          {% callback_names << r[2].stringify.gsub(/^:/, "") %}
        {% end %}
      {% end %}

      class ::{{ t.stringify.id }}
        # Dispatch a routed action: run it, then default-render its
        # template inside the layout unless the action already rendered.
        # Around filters wrap the action (after before-filters, Rails
        # order).
        def __run_action_dispatch(action : String) : Nil
          __run_before_filters(action)
          return if @performed
          __run_around_filters(action) do
            case action
            {% for m in t.methods %}
              {% is_action = m.args.empty? && !m.name.stringify.starts_with?("__") && m.name.stringify != m.name.stringify.capitalize && !callback_names.includes?(m.name.stringify) %}
              {% if is_action %}
            when {{ m.name.stringify }}
              {{ m.name.id }}
              __default_render({{ m.name.stringify }}) unless @performed
              {% end %}
            {% end %}
            else
              raise ::ActionController::RoutingError.new(
                "Unknown action #{action} for #{self.class}")
            end
            nil
          end
        end

        # Registered around_action filters for this controller (its own
        # and inherited ones), run outside-in as nested blocks; each
        # filter yields to continue the chain, the innermost block is
        # the action itself. One generated method per step: a single
        # recursive method would trip Crystal's "recursive block
        # expansion" check.
        {% applicable_around = [] of NamedTuple %}
        {% for f in ActionController::AROUND_FILTERS %}
          {% if f[0] == t || t.ancestors.includes?(f[0]) %}
            {% applicable_around << {name: f[1], opts: f[2]} %}
          {% end %}
        {% end %}
        {% for f, i in applicable_around %}
          def __around_step_{{ i }}(action : String, &)
            if __callback_condition({{ f[:opts][:only] }}, {{ f[:opts][:except] }}, {{ f[:opts][:if] }}, {{ f[:opts][:unless] }})
              {{ f[:name].id }} { __around_step_{{ i + 1 }}(action) { yield } }
            else
              __around_step_{{ i + 1 }}(action) { yield }
            end
            nil
          end
        {% end %}
        def __around_step_{{ applicable_around.size }}(action : String, &)
          yield
          nil
        end

        def __run_around_filters(action : String, &)
          __around_step_0(action) { yield }
          nil
        end

        # Registered before_action filters for this controller (its own
        # and inherited ones). skip_before_action narrows the original
        # filter to the complement of the skip's only/except/if/unless
        # set (an unconditional skip disables it entirely) — Rails
        # callback-skip semantics; the old code dropped the filter for
        # ALL actions, ignoring the skip's conditions.
        # Symbol#stringify here carries a leading ":" — normalized off.
        def __run_before_filters(action : String) : Nil
          {% for f in ActionController::FILTERS %}
            {% if f[0] == t || t.ancestors.includes?(f[0]) %}
              {% fname = f[1].stringify.gsub(/^:/, "") %}
              {% unless fname.starts_with?("__skip_") %}
                {% skips = [] of Nil %}
                {% for s in ActionController::FILTERS %}
                  {% if s[0] == t || t.ancestors.includes?(s[0]) %}
                    {% sname = s[1].stringify.gsub(/^:/, "") %}
                    {% if sname.starts_with?("__skip_") && sname[7..] == fname %}
                      {% skips << s %}
                    {% end %}
                  {% end %}
                {% end %}
                if __callback_condition({{ f[2][:only] }}, {{ f[2][:except] }}, {{ f[2][:if] }}, {{ f[2][:unless] }}){% for s in skips %} && !__callback_condition({{ s[2][:only] }}, {{ s[2][:except] }}, {{ s[2][:if] }}, {{ s[2][:unless] }}){% end %}
                  {{ f[1].id }}
                  return if @performed
                end
              {% end %}
            {% end %}
          {% end %}
          nil
        end

        # rescue_from handlers for this controller (own + inherited).
        {% rescue_clauses = [] of String %}
        {% for r in ActionController::RESCUERS %}
          {% if r[0] == t || t.ancestors.includes?(r[0]) %}
            {% rescue_clauses << "rescue ex : " + r[1].stringify + "\n  " + r[2].stringify[1..] + "(ex)" %}
          {% end %}
        {% end %}
        {% unless rescue_clauses.empty? %}
          def __rescue_with_handlers(&) : Nil
            begin
              yield
            {% for clause in rescue_clauses %}
              {{ clause.id }}
            {% end %}
            end
          end

          def __run_action(action : String) : Nil
            __live_dispatch { __rescue_with_handlers { __run_action_dispatch(action) } }
          end
        {% else %}
          def __run_action(action : String) : Nil
            __live_dispatch { __run_action_dispatch(action) }
          end
        {% end %}

        # Render the action's ERB template with the controller as
        # context (instance variables, `params`, helpers are visible).
        # `format` = "html" (default) or "turbo_stream".
        def __render_view(action : String, format : String = "html") : ::ActionView::SafeString
          if format == "turbo_stream"
            return __render_view_turbo_stream(action)
          end
          case action
          {% for m in t.methods %}
            {% is_action = m.args.empty? && !m.name.stringify.starts_with?("__") && m.name.stringify != m.name.stringify.capitalize && !callback_names.includes?(m.name.stringify) %}
            {% if is_action %}
              {% path = root + "/" + dir + "/" + m.name.stringify + ".html.erb" %}
              {% missing_msg = "Missing template " + path %}
          when {{ m.name.stringify }}
            {% if (`(test -f #{path} && echo yes) || true`) != "" %}
              __av_tpl_{{ m.name.id }}
            {% else %}
              raise ::ActionController::RoutingError.new({{ missing_msg }})
            {% end %}
            {% end %}
          {% end %}
          else
            raise ::ActionController::RoutingError.new(
              "No template for #{action} (#{self.class})")
          end
        end

        # Turbo-stream формат: #{action}.turbo_stream.erb без layout.
        def __render_view_turbo_stream(action : String) : ::ActionView::SafeString
          case action
          {% for m in t.methods %}
            {% is_action = m.args.empty? && !m.name.stringify.starts_with?("__") && m.name.stringify != m.name.stringify.capitalize && !callback_names.includes?(m.name.stringify) %}
            {% if is_action %}
              {% ts_path = root + "/" + dir + "/" + m.name.stringify + ".turbo_stream.erb" %}
          when {{ m.name.stringify }}
            {% if (`(test -f #{ts_path} && echo yes) || true`) != "" %}
              __av_ts_tpl_{{ m.name.id }}
            {% else %}
              raise ::ActionController::RoutingError.new("Missing template " + {{ ts_path }})
            {% end %}
            {% end %}
          {% end %}
          else
            raise ::ActionController::RoutingError.new(
              "No template for #{action} (#{self.class})")
          end
        end

        # JSON-формат: #{action}.json.jbuilder (implicit render при
        # format=json / Accept: application/json — см. __default_render).
        def __jb_template?(action : String) : Bool
          case action
          {% for m in t.methods %}
            {% is_action = m.args.empty? && !m.name.stringify.starts_with?("__") && m.name.stringify != m.name.stringify.capitalize && !callback_names.includes?(m.name.stringify) %}
            {% if is_action %}
              {% jb_path = root + "/" + dir + "/" + m.name.stringify + ".json.jbuilder" %}
              {% if (`(test -f #{jb_path} && echo yes) || true`) != "" %}
            when {{ m.name.stringify }} then true
              {% end %}
            {% end %}
          {% end %}
          else
            false
          end
        end

        # Есть ли #{action}.turbo_stream.erb: implicit render при
        # turbo_stream-формате; иначе fallback на HTML (см. __default_render).
        def __ts_template?(action : String) : Bool
          case action
          {% for m in t.methods %}
            {% is_action = m.args.empty? && !m.name.stringify.starts_with?("__") && m.name.stringify != m.name.stringify.capitalize && !callback_names.includes?(m.name.stringify) %}
            {% if is_action %}
              {% ts_path = root + "/" + dir + "/" + m.name.stringify + ".turbo_stream.erb" %}
              {% if (`(test -f #{ts_path} && echo yes) || true`) != "" %}
            when {{ m.name.stringify }} then true
              {% end %}
            {% end %}
          {% end %}
          else
            false
          end
        end

        def __render_view_json(action : String) : String
          case action
          {% for m in t.methods %}
            {% is_action = m.args.empty? && !m.name.stringify.starts_with?("__") && m.name.stringify != m.name.stringify.capitalize && !callback_names.includes?(m.name.stringify) %}
            {% if is_action %}
              {% jb_path = root + "/" + dir + "/" + m.name.stringify + ".json.jbuilder" %}
              {% if (`(test -f #{jb_path} && echo yes) || true`) != "" %}
            when {{ m.name.stringify }} then __jb_tpl_{{ m.name.id }}
              {% end %}
            {% end %}
          {% end %}
          else
            raise ::ActionController::RoutingError.new(
              "Missing template #{action}.json.jbuilder (#{self.class})")
          end
        end

        # render(template:) — .json.jbuilder этого контроллера: полный путь
        # относительно корня вьюх с расширением или без ("posts/show.json.jbuilder"
        # / "posts/show") либо имя экшена ("show.json.jbuilder" / "show").
        def __jb_render_template(path : String) : String
          case path
          {% for m in t.methods %}
            {% is_action = m.args.empty? && !m.name.stringify.starts_with?("__") && m.name.stringify != m.name.stringify.capitalize && !callback_names.includes?(m.name.stringify) %}
            {% if is_action %}
              {% jb_path = root + "/" + dir + "/" + m.name.stringify + ".json.jbuilder" %}
              {% if (`(test -f #{jb_path} && echo yes) || true`) != "" %}
          when {{ jb_path }}                                  then __jb_tpl_{{ m.name.id }}
          when {{ dir + "/" + m.name.stringify + ".json.jbuilder" }} then __jb_tpl_{{ m.name.id }}
          when {{ dir + "/" + m.name.stringify }}             then __jb_tpl_{{ m.name.id }}
          when {{ m.name.stringify + ".json.jbuilder" }}      then __jb_tpl_{{ m.name.id }}
          when {{ m.name.stringify }}                         then __jb_tpl_{{ m.name.id }}
              {% end %}
            {% end %}
          {% end %}
          else
            raise ::ActionController::RoutingError.new(
              "Missing template #{path} (.json.jbuilder) for #{self.class}")
          end
        end

        {% for m in t.methods %}
          {% is_action = m.args.empty? && !m.name.stringify.starts_with?("__") && m.name.stringify != m.name.stringify.capitalize && !callback_names.includes?(m.name.stringify) %}
          {% if is_action %}
            {% tpl_dedent = t.annotations(::ActionController::NoTemplateDedent).size == 0 %}
            {% path = root + "/" + dir + "/" + m.name.stringify + ".html.erb" %}
            {% if (`(test -f #{path} && echo yes) || true`) != "" %}
              compile_template "__av_tpl_{{ m.name.id }}", {{ path }}, dedent: {{ tpl_dedent }}
            {% end %}
            {% ts_path = root + "/" + dir + "/" + m.name.stringify + ".turbo_stream.erb" %}
            {% if (`(test -f #{ts_path} && echo yes) || true`) != "" %}
              compile_template "__av_ts_tpl_{{ m.name.id }}", {{ ts_path }}, dedent: {{ tpl_dedent }}
            {% end %}
            {% jb_path = root + "/" + dir + "/" + m.name.stringify + ".json.jbuilder" %}
            {% if (`(test -f #{jb_path} && echo yes) || true`) != "" %}
              JbuilderHandler.call "__jb_tpl_{{ m.name.id }}", {{ jb_path }}
            {% end %}
          {% end %}
        {% end %}

        {% layout_path = root + "/layouts/application.html.erb" %}
        {% if (`(test -f #{layout_path} && echo yes) || true`) != "" %}
          compile_layout "__av_layout", {{ layout_path }}

          def __render_layout(& : -> String) : String
            __av_layout { yield }.to_s
          end
        {% else %}
          def __render_layout(& : -> String) : String
            yield
          end
        {% end %}
      end
    {% end %}
  {% end %}

  # Resolve a route's controller name ("welcome", "admin/posts") to the
  # compile-time-registered controller class.
  module ActionController
    module Dispatch
      def self.resolve(controller_name : String)
        case controller_name
        {% for t in ActionController::REGISTRY %}
          {% unless t.abstract? %}
            {% parts = t.name.split("::") %}
            {% key = parts.last.underscore.gsub(/_controller$/, "") %}
            {% if parts.size > 1 %}
              {% key = parts[0...-1].map(&.underscore).join("/") + "/" + key %}
            {% end %}
        when {{ key }} then {{ t.stringify.id }}
          {% end %}
        {% end %}
        else
          nil
        end
      end
    end
  end
end
