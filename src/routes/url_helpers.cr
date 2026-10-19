# Named route helpers (`*_path` / `*_url`) — the Rails url_helpers
# analogue. Routes are drawn at RUNTIME (`config/routes.cr` runs as
# plain code after the controllers are compiled), so a compile-time
# table is not an option; instead each call to a missing `*_path`/
# `*_url` method expands — via `macro method_missing`, the pattern
# already used by action_view_cr's TagBuilder — into a method that
# resolves the name against the route set at runtime and builds the
# path. `method_missing` only fires when no explicit method exists:
# hand-written helpers in the app keep shadowing generated ones.
#
# Semantics (minimal Rails parity, see README "Named route helpers"):
# - positional args fill dynamic segments left-to-right; objects
#   responding to `to_param` are converted (room_path(room));
# - extra positional args go to the query string (key = value);
# - named opts become query params, `anchor:` becomes the fragment;
# - `*_url` = origin + `*_path`; origin is the request's `origin`
#   method when the including context has one (controllers), then
#   `jb_origin` (Jbuilder partials), then `default_url_origin`.
module CRails::Routes::UrlHelpers
  # Route set the generated helpers resolve against. The application
  # (railties_cr) points this at `CRails.application.routes` at boot;
  # specs assign their own. action_pack_cr cannot reach CRails.application
  # itself (railties_cr depends on action_pack_cr, not vice versa).
  class_property route_set : RouteSet?

  # Fallback origin for `*_url` outside a request context (jobs,
  # Jbuilder partials) — the `default_url_options` host analogue.
  class_property default_url_origin : String = "http://localhost"

  macro method_missing(call)
    {% name = call.name.stringify %}
    {% if name.ends_with?("_path") || name.ends_with?("_url") %}
      # Generated signature ignores call.args' restrictions on purpose:
      # helpers take any positional mix plus named query params.
      def {{call.name.id}}(*args, **opts) : String
        __crails_url_helper({{name}}, args, opts)
      end
    {% else %}
      {% raise "Undefined method #{name}: route helpers are generated only for names ending in _path/_url" %}
    {% end %}
  end

  # Shared runtime of the generated methods. Defined on the including
  # instance so `*_url` can ask the request context for its origin.
  private def __crails_url_helper(name : String, args, opts) : String
    set = UrlHelpers.route_set ||
      raise ArgumentError.new("CRails::Routes::UrlHelpers.route_set is not set (assign CRails.application.routes at boot)")
    # `*_url`/`*_path` helpers share one route name (the suffix is cut)
    route_name = name.ends_with?("_url") ? name.rchop("_url") : name.rchop("_path")
    values = [] of String
    args.each { |arg| values << UrlHelpers.__to_param(arg) }
    anchor = nil
    query = [] of Tuple(String, String)
    opts.each do |key, value|
      if key.to_s == "anchor"
        anchor = UrlHelpers.__to_param(value)
      else
        query << {key.to_s, UrlHelpers.__to_param(value)}
      end
    end
    path = set.path_for(route_name, values)
    unless query.empty?
      qs = query.map { |k, v| "#{URI.encode_www_form(k)}=#{URI.encode_www_form(v)}" }.join("&")
      path += (path.includes?('?') ? "&" : "?") + qs
    end
    path += "#" + URI.encode_www_form(anchor) if anchor
    name.ends_with?("_url") ? __crails_url_origin + path : path
  end

  # Controllers expose `origin` (scheme://host of the request), usually
  # defined on the application's ApplicationController — i.e. an ANCESTOR
  # of the concrete controller — and Jbuilder partials carry `jb_origin`;
  # everything else falls back to the configured default (jobs, tests).
  # The check is compile-time and walks the ancestor chain: a dead
  # `origin` branch would otherwise trip method_missing in contexts
  # that don't define it (`@type.methods` alone lists only the type's
  # own methods, missing inherited ones).
  private def __crails_url_origin : String
    {% begin %}
      {% origin_here = @type.methods.any? { |m| m.name.stringify == "origin" } ||
                       @type.ancestors.any? { |t| t.methods.any? { |m| m.name.stringify == "origin" } } %}
      {% jb_origin_here = @type.methods.any? { |m| m.name.stringify == "jb_origin" } ||
                          @type.ancestors.any? { |t| t.methods.any? { |m| m.name.stringify == "jb_origin" } } %}
      {% if origin_here %}
        origin.to_s
      {% elsif jb_origin_here %}
        jb_origin.to_s
      {% else %}
        UrlHelpers.default_url_origin
      {% end %}
    {% end %}
  end

  # Rails `to_param` semantics: objects may customize their URL
  # representation; everything else goes through `to_s`.
  def self.__to_param(arg) : String
    arg.responds_to?(:to_param) ? arg.to_param : arg.to_s
  end
end
