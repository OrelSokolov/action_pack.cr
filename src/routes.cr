module CRails
  module Routes
    struct Route
      getter verb : String
      getter segments : Array(String)
      getter controller : String # e.g. "welcome"
      getter action : String     # e.g. "index"
      getter name : String?      # e.g. "root"

      def initialize(@verb : String, pattern : String, to : String, @name : String? = nil)
        @segments = pattern.split("/").reject(&.empty?)
        @controller, @action = to.split("#", 2)
      end

      def pattern : String
        "/" + @segments.join("/")
      end
    end

    struct Match
      getter route : Route
      getter params : Hash(String, String)

      def initialize(@route, @params)
      end
    end

    class RouteSet
      getter routes = [] of Route

      # `with ... yield` makes the block a DSL: bare `root`/`get`/...
      # calls inside `draw do ... end` are routed to the Drawer.
      def draw(&) : Nil
        with drawer yield
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
          if pattern.starts_with?(":")
            params[pattern[1..]] = URI.decode_www_form(actual)
          else
            return nil unless pattern == actual
          end
        end
        params
      end
    end

    # DSL object yielded by `CRails.application.routes.draw do ... end`.
    class Drawer
      def initialize(@set : RouteSet)
      end

      def root(to : String) : Nil
        get "/", to: to, as: "root"
      end

      # `openapi "/openapi.json"` — mount the built-in document endpoint
      # (CRails::OpenApiController, Iteration 10). Serving is opt-in:
      # the drawer call is the only wiring needed. Controller key is
      # "c_rails/open_api": Dispatch.resolve underscores each namespace
      # segment ("CRails" -> "c_rails").
      def openapi(path : String = "/openapi.json") : Nil
        get path, to: "c_rails/open_api#show", as: "open_api"
      end

      # `resources :posts` — the seven RESTful routes Rails draws for a
      # resource (used by `crails generate scaffold`).
      def resources(name : String | Symbol) : Nil
        name = name.to_s
        get "/#{name}", to: "#{name}#index", as: name
        get "/#{name}/new", to: "#{name}#new", as: "new_#{name.singularize}"
        get "/#{name}/:id/edit", to: "#{name}#edit", as: "edit_#{name.singularize}"
        get "/#{name}/:id", to: "#{name}#show", as: name.singularize
        post "/#{name}", to: "#{name}#create"
        patch "/#{name}/:id", to: "#{name}#update"
        put "/#{name}/:id", to: "#{name}#update"
        delete "/#{name}/:id", to: "#{name}#destroy"
      end

      # `as` is a Crystal keyword, so the Rails-style `to:`/`as:` options
      # are read from **opts.
      {% for verb in %w(get post put patch delete) %}
        def {{verb.id}}(path : String, **opts) : Nil
          add({{ verb.upcase }}, path,
            opts["to"]?.as?(String),
            opts["as"]?.as?(String))
        end
      {% end %}

      private def add(verb : String, path : String, to : String?, name : String?) : Nil
        raise ArgumentError.new("route needs a `to:` target (\"controller#action\")") unless to
        @set.routes << Route.new(verb, path, to, name)
      end
    end
  end
end
