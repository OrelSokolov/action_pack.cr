# ActionController::RateLimiting — port of actionpack 8.1.4
# lib/action_controller/metal/rate_limiting.rb (Iteration 12).
#
# Oracle: oracle/rate_limit_expected.yml (18 cases, actionpack 8.1.4),
# mirrored in railties.cr/spec/rate_limit_spec.cr.
#
# `rate_limit to:, within:` registers a before-filter (so `only:` /
# `except:` work through the normal filter machinery). Requests over
# the limit run the `with:` handler (a controller method) or raise
# TooManyRequests — the CRails request layer maps that to 429, like
# ActionDispatch::ShowExceptions does.
#
# Counting relies on ActiveSupport::Cache#increment with expires_in —
# a FIXED window from the first request (the store keeps the entry's
# original expiry on increment). Rails options mapped:
#   to:/within: — limit and window
#   by:         — controller method name returning bucket identity
#                 (default: remote ip)
#   with:       — controller method name for the over-limit response
#   store:      — cache store expression (default: RateLimiting
#                 default store, a MemoryStore)
#   name:/scope: — share/separate buckets across limits/controllers
#
# Documented deviations from the Ruby gem: `by:`/`with:` take a method
# name (Symbol) instead of an evaluated lambda — Crystal has no
# instance_exec on arbitrary procs; the instrument payload's
# "request" is the request path and "within" a String (ActiveSupport
# payload values are scalars in the Crystal port).

module ActionController
  class TooManyRequests < Exception
  end

  module RateLimiting
    # Compile-time counter for unique generated filter method names.
    LIMITS = [] of Nil

    @@default_store : ActiveSupport::Cache::Store = ActiveSupport::Cache::MemoryStore.new

    def self.default_store : ActiveSupport::Cache::Store
      @@default_store
    end

    # Apps can point this at a shared store (PG/Redis) — Rails does the
    # same via config.action_controller.cache_store.
    def self.default_store=(store : ActiveSupport::Cache::Store) : ActiveSupport::Cache::Store
      @@default_store = store
    end

    # `with:` is a Crystal keyword (like `as:` in routes), so it is read
    # from **opts — the call site still reads `with: :handler`.
    macro rate_limit(to, within, only = nil, except = nil, by = nil, store = nil, name = nil, scope = nil, **opts)
      {% with_handler = opts["with"] %}
      {% limit_id = "__rate_limit_#{ActionController::RateLimiting::LIMITS.size}".id %}
      {% limit_sym = limit_id.symbolize %}
      {% ActionController::RateLimiting::LIMITS << nil %}
      {% parts = @type.name.split("::") %}
      {% controller_path = parts.last.underscore.gsub(/_controller$/, "") %}
      {% scope_s = scope || controller_path %}
      {% name_s = name %}
      {% if store %}
        {% store_expr = store %}
      {% else %}
        {% store_expr = "ActionController::RateLimiting.default_store".id %}
      {% end %}

      def {{ limit_id }} : Nil
        identity = {% if by %} {{ by.id }} {% else %} __remote_ip {% end %}
        cache_key = ["rate-limit", {{ scope_s }}, {{ name_s }}, identity].compact.join(":")
        count = {{ store_expr }}.increment(cache_key, 1, expires_in: {{ within }})
        if count && count > {{ to }}
          payload = {
            "request"   => request.path,
            "count"     => count,
            "to"        => {{ to }},
            "within"    => {{ within }}.to_s,
            "by"        => identity,
            "name"      => {{ name_s }},
            "scope"     => {{ scope_s }},
            "cache_key" => cache_key,
          } of String => ActiveSupport::Any
          ActiveSupport::Notifications.instrument("rate_limit.action_controller", payload) do
            {% if with_handler %}
              {{ with_handler.id }}
            {% else %}
              raise ::ActionController::TooManyRequests.new
            {% end %}
          end
        end
      end

      {% ActionController::FILTERS << { @type, limit_sym, {only: only, except: except} } %}
    end
  end

  class Base
    include RateLimiting

    # Bucket identity for rate_limit defaults — Rails request.remote_ip.
    protected def __remote_ip : String
      if (fwd = request.headers["X-Forwarded-For"]?) && !fwd.empty?
        return fwd.split(',').first.strip
      end
      case addr = request.remote_address
      when Socket::IPAddress then addr.address.to_s
      else                        "unknown"
      end
    end
  end
end
