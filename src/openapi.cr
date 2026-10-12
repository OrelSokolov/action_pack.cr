require "json"

# CRails::OpenAPI — Iteration 10: OpenAPI compile-time codegen.
#
# Builds an OpenAPI 3.0.3 document from the route table plus the
# `typed_params` schema registry (both declared at compile time — the
# document reflects the code, not hand-written YAML). The generated
# document is validated against the real openapi3_parser gem in the
# spec (oracle/verify_openapi.rb) and served by the built-in
# `CRails::OpenApiController` (mount with `openapi` in the routes
# drawer; railties assigns `CRails::OpenAPI.routes` at boot).
#
# Mapping:
# - route "/posts/:id" → path "/posts/{id}" + path parameter
# - verb → operation key; operationId "<controller>_<action>"
#   (Rails route-name style), tags: [<controller>]
# - POST/PATCH/PUT with a typed schema → requestBody
#   application/json JSON Schema (types, required, sizes, bounds)
# - GET/DELETE with a typed schema → top-level scalar/array fields as
#   query parameters (documented deviation: nested hash fields are not
#   described in query — Rails form encoding `a[b]` is not
#   representable as an OpenAPI query parameter)
# - 3.0.3 (not 3.1): `nullable: true` instead of type arrays — widest
#   tooling compatibility and what the reference validator supports.

module CRails
  module OpenAPI
    class_property routes : ::CRails::Routes::RouteSet = ::CRails::Routes::RouteSet.new

    BODY_VERBS = {"POST", "PATCH", "PUT"}

    def self.document(title : String = "CRails API", version : String = "1.0.0") : String
      groups = [] of {String, Array(::CRails::Routes::Route)}
      index = {} of String => Int32
      routes.routes.each do |r|
        p = openapi_path(r)
        if i = index[p]?
          groups[i][1] << r
        else
          index[p] = groups.size
          groups << {p, [r] of ::CRails::Routes::Route}
        end
      end

      JSON.build do |j|
        j.object do
          j.field("openapi", "3.0.3")
          j.field("info") do
            j.object do
              j.field("title", title)
              j.field("version", version)
            end
          end
          j.field("paths") do
            j.object do
              groups.each do |path, rs|
                j.field(path) do
                  j.object do
                    rs.each do |r|
                      j.field(r.verb.downcase) { write_operation(j, r) }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    def self.openapi_path(route : ::CRails::Routes::Route) : String
      "/" + route.segments.map { |s| s.starts_with?(":") ? "{#{s[1..]}}" : s }.join("/")
    end

    def self.find_schema(route : ::CRails::Routes::Route)
      ::ActionController::TypedParams::SCHEMAS.find { |s|
        s.controller == route.controller && s.action == route.action
      }
    end

    def self.write_operation(j : JSON::Builder, route : ::CRails::Routes::Route) : Nil
      j.object do
        j.field("operationId", "#{route.controller.gsub('/', '_')}_#{route.action}")
        j.field("tags") { j.array { j.scalar(route.controller) } }

        path_params = route.segments.select(&.starts_with?(":"))
        query_fields = if BODY_VERBS.includes?(route.verb)
                         nil
                       else
                         find_schema(route).try(&.fields.reject { |f| f.kind == :hash })
                       end
        if !path_params.empty? || (qf = query_fields) && !qf.empty?
          j.field("parameters") do
            j.array do
              path_params.each do |seg|
                j.object do
                  j.field("name", seg[1..])
                  j.field("in", "path")
                  j.field("required", true)
                  j.field("schema") { j.object { j.field("type", "string") } }
                end
              end
              query_fields.try(&.each do |f|
                j.object do
                  j.field("name", f.key)
                  j.field("in", "query")
                  j.field("required", f.required?)
                  j.field("schema") { write_field_schema(j, f) }
                end
              end)
            end
          end
        end

        if BODY_VERBS.includes?(route.verb) && (schema = find_schema(route))
          j.field("requestBody") do
            j.object do
              j.field("required", schema.fields.any?(&.required?))
              j.field("content") do
                j.object do
                  j.field("application/json") do
                    j.object do
                      j.field("schema") { write_object_schema(j, schema.fields) }
                    end
                  end
                end
              end
            end
          end
        end

        j.field("responses") do
          j.object do
            j.field("200") { j.object { j.field("description", "OK") } }
          end
        end
      end
    end

    def self.write_object_schema(j : JSON::Builder, fields) : Nil
      j.object do
        j.field("type", "object")
        j.field("properties") do
          j.object do
            fields.each do |f|
              j.field(f.key) { write_field_schema(j, f) }
            end
          end
        end
        req = fields.select(&.required?).map(&.key)
        unless req.empty?
          j.field("required") { j.array { req.each { |k| j.scalar(k) } } }
        end
      end
    end

    def self.write_field_schema(j : JSON::Builder, f) : Nil
      case f.kind
      when :hash
        write_object_schema(j, f.sub.not_nil!)
      when :array_string, :array_int32, :array_int64, :array_float64, :array_bool
        elem = f.element_kind
        j.object do
          j.field("type", "array")
          j.field("items") { write_scalar_schema(j, elem, false, nil, nil, nil, nil) }
          write_bounds(j, f)
        end
      else
        write_scalar_schema(j, f.kind, f.nilable?, f.min_size, f.max_size, f.gteq, f.lteq)
      end
    end

    def self.write_scalar_schema(j : JSON::Builder, kind : Symbol, nilable : Bool,
                                 min_size, max_size, gteq, lteq) : Nil
      j.object do
        case kind
        when :string  then j.field("type", "string")
        when :float64 then j.field("type", "number")
        when :bool    then j.field("type", "boolean")
        else               j.field("type", "integer")
        end
        if kind == :string
          j.field("minLength", min_size) if min_size
          j.field("maxLength", max_size) if max_size
        end
        if gteq
          j.field("minimum", scalar_num(gteq))
        end
        if lteq
          j.field("maximum", scalar_num(lteq))
        end
        j.field("nullable", true) if nilable
      end
    end

    def self.write_bounds(j : JSON::Builder, f) : Nil
      j.field("minItems", f.min_size) if f.min_size
      j.field("maxItems", f.max_size) if f.max_size
    end

    def self.scalar_num(v : Float64) : Int64 | Float64
      v == v.trunc ? v.trunc.to_i64 : v
    end
  end
end

# Built-in controller serving the document (dispatch key
# "crails/open_api" — mount via `openapi "/openapi.json"` in the
# routes drawer).
class CRails::OpenApiController < ActionController::Base
  def show
    render json: CRails::OpenAPI.document
  end
end
