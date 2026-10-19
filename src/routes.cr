module CRails
  module Routes
    struct Route
      attr_reader verb : String
      attr_reader segments : Array(String)
      attr_reader controller : String # e.g. "welcome"
      attr_reader action : String     # e.g. "index"
      attr_reader name : String?      # e.g. "root"
      # `scope defaults: { ... }` / `resources defaults: { ... }` — params
      # filled in when the path doesn't set them (segment params win).
      attr_reader defaults : Hash(String, String)
      # "file:line" of the DSL call that drew the route (config/routes.rb)
      # — the "Source Location" column the Rails dev Routing Error page
      # shows. Filled from __FILE__/__LINE__ defaults resolved at the
      # call site, nil for routes emitted without them.
      attr_reader source : String?

      def initialize(@verb : String, pattern : String, to : String, @name : String? = nil,
                     @defaults : Hash(String, String) = Hash(String, String).new,
                     @source : String? = nil)
        @segments = pattern.split("/").reject(&.empty?)
        @controller, @action = to.split("#", 2)
      end

      def pattern : String
        "/" + @segments.join("/")
      end
    end

    struct Match
      attr_reader route : Route
      attr_reader params : Hash(String, String)

      def initialize(@route, @params)
      end
    end

    class RouteSet
      attr_reader routes = [] of Route

      @named_routes : Hash(String, Route)?

      # `with ... yield` makes the block a DSL: bare `root`/`get`/...
      # calls inside `draw do ... end` are routed to the Drawer.
      def draw(&) : Nil
        with drawer yield
      end

      # Index name → route for URL generation (the reverse direction of
      # `match`). Built lazily on the first lookup; the last route drawn
      # with a given name wins, as in Rails.
      def named_routes : Hash(String, Route)
        @named_routes ||= routes.each_with_object({} of String => Route) do |route, index|
          if (name = route.name)
            index[name] = route
          end
        end
      end

      # Builds a URL path for a named route — the runtime behind the
      # `*_path`/`*_url` helpers (Routes::UrlHelpers). Positional args
      # fill the dynamic segments left-to-right, url-encoded; literal
      # prefixes ("@:message_id") keep the prefix and encode only the
      # value. Leftover args become query params with the value as both
      # key and value, as Rails does for unnamed extras. Raises
      # ArgumentError (the UrlGenerationError analogue) on an unknown
      # name or missing segment values.
      def path_for(name : String, args : Array(String)) : String
        route = named_routes[name]?
        raise ArgumentError.new("No route named #{name}") unless route
        parts = [] of String
        rest = args.dup
        route.segments.each do |segment|
          colon = segment.index(':')
          if colon && (colon == 0 || segment.size > colon)
            if rest.empty?
              raise ArgumentError.new(
                "No route named #{name} matches the given arguments: missing value for segment #{segment}")
            end
            prefix = colon == 0 ? "" : segment[0...colon]
            parts << prefix + URI.encode_www_form(rest.shift)
          else
            parts << segment
          end
        end
        path = "/" + parts.join("/")
        unless rest.empty?
          query = rest.map { |value| "#{URI.encode_www_form(value)}=#{URI.encode_www_form(value)}" }.join("&")
          path += "?" + query
        end
        path
      end

      private def drawer : Drawer
        Drawer.new(self)
      end

      def match(verb : String, path : String) : Match?
        parts = path.split("/").reject(&.empty?)
        @routes.each do |route|
          params = match_route?(route, verb, parts)
          return Match.new(route, params) if params
        end
        nil
      end

      private def match_route?(route : Route, verb : String, parts : Array(String)) : Hash(String, String)?
        return nil unless route.verb == verb
        return nil unless route.segments.size == parts.size
        params = {} of String => String
        route.segments.zip(parts) do |pattern, actual|
          # ":id" — полный сегмент-параметр; "@:message_id" — литеральный
          # префикс + параметр (Rails-style `get "@:message_id"`).
          if (colon = pattern.index(':')) && (colon == 0 || actual.size > colon)
            if colon == 0 || pattern[0...colon] == actual[0...colon]
              params[pattern[(colon + 1)..]] = URI.decode_www_form(actual[colon..])
            else
              return nil
            end
          else
            return nil unless pattern == actual
          end
        end
        # Defaults fill only params the path left unset.
        route.defaults.each do |key, value|
          params[key] = value unless params.has_key?(key)
        end
        params
      end
    end

    # DSL object yielded by `CRails.application.routes.draw do ... end`.
    # Mirrors ActionDispatch::Routing: `resources`/`resource` (with blocks
    # for nesting), `scope`, `namespace`, `member`/`collection` and the
    # plain verb helpers. Matching is a linear first-match scan, so draw
    # literal segments before dynamic ones (`get "/users/me/..."` before
    # `resources :users`).
    class Drawer
      private RESOURCE_ACTIONS = %w[index new edit show create update destroy]
      private SINGULAR_ACTIONS  = %w[new create edit update show destroy]

      def initialize(@set : RouteSet)
        @path_prefix = [] of String    # scope/resource path segments
        @name_prefix = [] of String    # route-name ("as") segments, joined with "_"
        @module_prefix = [] of String  # controller module segments (namespace/module:)
        @scope_defaults = Hash(String, String).new
        @member_params = [] of String  # trailing ":param" segments pushed by `resources` blocks
        @default_controllers = [] of String # `delete "clear"` inside a resources block
      end

      def root(to : String, *, file : String = __FILE__, line : Int32 = __LINE__) : Nil
        get "/", to: to, as: "root", file: file, line: line
      end

      # `openapi "/openapi.json"` — mount the built-in document endpoint
      # (CRails::OpenApiController, Iteration 10). Serving is opt-in:
      # the drawer call is the only wiring needed. Controller key is
      # "c_rails/open_api": Dispatch.resolve underscores each namespace
      # segment ("CRails" -> "c_rails").
      def openapi(path : String = "/openapi.json", *,
                  file : String = __FILE__, line : Int32 = __LINE__) : Nil
        get path, to: "c_rails/open_api#show", as: "open_api", file: file, line: line
      end

      # `scope path: "...", module: "...", as: "...", defaults: {..."` —
      # nests paths, controller modules, route names and default params for
      # the block. `module` and `as` are Crystal keywords, so all options are
      # read from **opts. A leading "/" in a `to:` controller ("rooms#show")
      # opts out of the module prefix, as in Rails.
      def scope(**opts, &) : Nil
        saved = snapshot
        path = opts["path"]?.try(&.to_s)
        @path_prefix += path.split("/").reject(&.empty?) if path
        if (mod = opts["module"]?.try(&.to_s)) && !mod.empty?
          @module_prefix << mod
        end
        if (as_name = opts["as"]?.try(&.to_s)) && !as_name.empty?
          @name_prefix << as_name
        end
        @scope_defaults = defaults_of(opts, @scope_defaults)
        begin
          with self yield
        ensure
          restore(saved)
        end
      end

      # `namespace :admin` — scope(path: "admin", module: "admin", as: "admin"):
      # /admin/posts -> admin/posts#index.
      def namespace(name : String | Symbol, &) : Nil
        name = name.to_s
        scope(path: name, module: name, as: name) { with self yield }
      end

      # `resources :posts` — the seven RESTful routes Rails draws for a
      # resource, in Rails draw order (index, new, edit, show, create,
      # PATCH+PUT update, destroy). Options: `only:`/`except:` (array or
      # single action), `controller:`, `param:` (default "id"), `path:`,
      # `as:`, `defaults:`. A block nests routes under the member path
      # (`/posts/:post_id/...`); plain verb calls inside it are member
      # routes by default — wrap them in `collection { }` (or pass
      # `on: :collection`) for collection scope.
      # `resources :posts` without a block (see the block form below).
      def resources(name : String | Symbol, *, file : String = __FILE__, line : Int32 = __LINE__,
                    **opts) : Nil
        resources(name, **opts.merge(file: file, line: line)) { }
      end

      def resources(name : String | Symbol, *, file : String = __FILE__, line : Int32 = __LINE__,
                    **opts, &) : Nil
        name = name.to_s
        res_path = opts["path"]?.try(&.to_s) || name
        controller = opts["controller"]?.try(&.to_s) || name
        param = opts["param"]?.try(&.to_s) || "id"
        as_name = opts["as"]?.try(&.to_s) || name
        defaults = defaults_of(opts, @scope_defaults)

        base = @path_prefix + [res_path]
        member = base + [":#{param}"]
        singular = as_name.singularize
        ctrl = prefix_module(controller)

        source = "#{file}:#{line}"
        wanted = wanted_actions(opts, RESOURCE_ACTIONS)
        if wanted.includes?("index")
          emit("GET", base, "#{ctrl}#index", compose_name(as_name), defaults, source)
        end
        if wanted.includes?("new")
          emit("GET", base + ["new"], "#{ctrl}#new", "new_" + (@name_prefix + [singular]).join("_"), defaults, source)
        end
        if wanted.includes?("edit")
          emit("GET", member + ["edit"], "#{ctrl}#edit", "edit_" + (@name_prefix + [singular]).join("_"), defaults, source)
        end
        if wanted.includes?("show")
          emit("GET", member, "#{ctrl}#show", compose_name(singular), defaults, source)
        end
        if wanted.includes?("create")
          emit("POST", base, "#{ctrl}#create", nil, defaults, source)
        end
        if wanted.includes?("update")
          emit("PATCH", member, "#{ctrl}#update", nil, defaults, source)
          emit("PUT", member, "#{ctrl}#update", nil, defaults, source)
        end
        if wanted.includes?("destroy")
          emit("DELETE", member, "#{ctrl}#destroy", nil, defaults, source)
        end

        saved = snapshot
        @path_prefix = member
        @name_prefix = @name_prefix + [singular]
        @member_params << ":#{param}"
        @default_controllers << ctrl
        begin
          with self yield
        ensure
          restore(saved)
        end
      end

      # `resource :session` — the singular-resource routes Rails draws:
      # /session/new, POST /session, /session/edit, PATCH+PUT /session,
      # GET /session, DELETE /session. The controller is the pluralized
      # name ("sessions"), overridable with `controller:`. A block nests
      # routes under the plain path (no :id segment — /session/transfers).
      # `resource :session` without a block (see the block form below).
      def resource(name : String | Symbol, *, file : String = __FILE__, line : Int32 = __LINE__,
                   **opts) : Nil
        resource(name, **opts.merge(file: file, line: line)) { }
      end

      def resource(name : String | Symbol, *, file : String = __FILE__, line : Int32 = __LINE__,
                   **opts, &) : Nil
        name = name.to_s
        res_path = opts["path"]?.try(&.to_s) || name
        controller = opts["controller"]?.try(&.to_s) || name.pluralize
        as_name = opts["as"]?.try(&.to_s) || name
        defaults = defaults_of(opts, @scope_defaults)

        base = @path_prefix + [res_path]
        ctrl = prefix_module(controller)

        source = "#{file}:#{line}"
        wanted = wanted_actions(opts, SINGULAR_ACTIONS)
        if wanted.includes?("new")
          emit("GET", base + ["new"], "#{ctrl}#new", "new_" + (@name_prefix + [as_name]).join("_"), defaults, source)
        end
        if wanted.includes?("create")
          emit("POST", base, "#{ctrl}#create", nil, defaults, source)
        end
        if wanted.includes?("edit")
          emit("GET", base + ["edit"], "#{ctrl}#edit", "edit_" + (@name_prefix + [as_name]).join("_"), defaults, source)
        end
        if wanted.includes?("update")
          emit("PATCH", base, "#{ctrl}#update", nil, defaults, source)
          emit("PUT", base, "#{ctrl}#update", nil, defaults, source)
        end
        if wanted.includes?("show")
          emit("GET", base, "#{ctrl}#show", compose_name(as_name), defaults, source)
        end
        if wanted.includes?("destroy")
          emit("DELETE", base, "#{ctrl}#destroy", nil, defaults, source)
        end

        saved = snapshot
        @path_prefix = base
        @name_prefix = @name_prefix + [as_name]
        @default_controllers << ctrl
        begin
          with self yield
        ensure
          restore(saved)
        end
      end

      # Routes inside a `resources` block are member routes by default;
      # `collection { ... }` drops the trailing ":id" segment for the block
      # (like `on: :collection` on a single route). `member { ... }` is
      # accepted for Rails parity and changes nothing.
      def collection(&) : Nil
        saved = snapshot
        drop_member_segment
        begin
          with self yield
        ensure
          restore(saved)
        end
      end

      def member(&) : Nil
        with self yield
      end

      # `as` is a Crystal keyword, so the Rails-style `to:`/`as:` options
      # are read from **opts. `on: :collection` opts a single route out of
      # member scope inside a `resources` block; `defaults:` adds default
      # params; a controller with a leading "/" opts out of `scope module:`.
      {% for verb in %w(get post put patch delete) %}
        def {{verb.id}}(path : String, *, file : String = __FILE__, line : Int32 = __LINE__, **opts) : Nil
          add({{ verb.upcase }}, path, opts, file, line)
        end
      {% end %}

      private def add(verb : String, path : String, opts, file : String, line : Int32) : Nil
        to = opts["to"]?.try(&.to_s)
        if to.nil? && (ctrl = @default_controllers.last?)
          # `delete "clear"` inside a resources block — the resource's
          # controller with the first path segment as the action, as in Rails.
          action = path.split("/").reject(&.empty?).first?.try(&.tr("@:", ""))
          to = "#{ctrl}##{action}" if action && !action.empty?
        end
        raise ArgumentError.new("route needs a `to:` target (\"controller#action\")") unless to
        name = opts["as"]?.try(&.to_s)
        defaults = defaults_of(opts, @scope_defaults)
        prefix = @path_prefix
        if opts["on"]?.try(&.to_s) == "collection" &&
           !@member_params.empty? && prefix.last? == @member_params.last
          prefix = prefix[0...-1]
        end
        segments = prefix + path.split("/").reject(&.empty?)
        controller, action = to.split("#", 2)
        emit(verb, segments, "#{prefix_module(controller)}##{action}", compose_name(name), defaults,
          "#{file}:#{line}")
      end

      private def emit(verb : String, segments : Array(String), to : String,
                       name : String?, defaults : Hash(String, String), source : String? = nil) : Nil
        @set.routes << Route.new(verb, "/" + segments.join("/"), to, name, defaults, source)
      end

      private def drop_member_segment : Nil
        return if @member_params.empty?
        return unless @path_prefix.last? == @member_params.last
        @path_prefix = @path_prefix[0...-1]
        @member_params.pop
      end

      private def prefix_module(controller : String) : String
        return controller[1..] if controller.starts_with?("/")
        @module_prefix.empty? ? controller : (@module_prefix + [controller]).join("/")
      end

      private def compose_name(name : String?) : String?
        name ? (@name_prefix + [name]).join("_") : nil
      end

      private def wanted_actions(opts, all : Array(String)) : Array(String)
        except = action_list(opts["except"]?)
        if (only_value = opts["only"]?)
          # `only: []` — пустой набор, как в Rails (ничего не рисуется).
          action_list(only_value).select { |action| !except.includes?(action) }
        else
          all.select { |action| !except.includes?(action) }
        end
      end

      private def action_list(value) : Array(String)
        case value
        when String, Symbol then [value.to_s]
        when Array          then value.map(&.to_s)
        else                     [] of String
        end
      end

      private def defaults_of(opts, base = Hash(String, String).new) : Hash(String, String)
        value = opts["defaults"]?
        return base unless value
        result = base.dup
        if hash = value.as?(Hash)
          hash.each { |key, val| result[key.to_s] = val.to_s }
        elsif tuple = value.as?(NamedTuple)
          tuple.each { |key, val| result[key.to_s] = val.to_s }
        end
        result
      end

      private def snapshot
        {@path_prefix.dup, @name_prefix.dup, @module_prefix.dup, @scope_defaults.dup,
         @member_params.dup, @default_controllers.dup}
      end

      private def restore(state) : Nil
        @path_prefix, @name_prefix, @module_prefix, @scope_defaults,
          @member_params, @default_controllers = state
      end
    end
  end
end
