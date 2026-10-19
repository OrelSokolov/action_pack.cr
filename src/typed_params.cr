require "json"

# ActionController::TypedParams — Iteration 10: type-safe params.
#
# Compile-time typed parameters for actions. The `typed_params` macro DSL
# declares a schema per action; expansion generates a result class with
# TYPED GETTERS (compile-checked access — the whole point on Crystal) and
# a validation engine whose coercion semantics mirror dry-schema 1.13.4
# `Dry::Schema.Params` mode (oracle/typed_params_cases.rb, captured from
# the original gem → oracle/typed_params_expected.yml).
#
#     class PostsController < ApplicationController
#       typed_params(:create) do
#         required :title, String, min_size: 3
#         required :age,   Int32, gteq: 0, lteq: 10
#         optional :admin, Bool?
#         required :tags,  Array(String), min_size: 1
#         required :author do              # nested hash
#           required :name, String
#         end
#       end
#
#       def create
#         fp = create_params              # TypedParams::Invalid → 422
#         fp.title                        # String — compile-time checked
#         fp.author.name                  # nested typed getter
#       end
#     end
#
# dry-schema mapping (oracle semantics):
# - `required :x, T`   → required(:x).filled(:t)
# - `required :x, T?`  → required(:x).maybe(:t)
# - `optional :x, T`   → optional(:x).filled(:t)
# - `optional :x, T?`  → optional(:x).maybe(:t)
# - `Array(T)`         → value(:array) { each(:t) } — empty array is valid
#   unless min_size: is given; nil/"" coerce to [] (dry-types Params)
# - block form         → .hash do ... end
#
# Documented deviations (static typing / Crystal):
# - DSL syntax differs from dry-schema predicates (semantics mirrored);
# - coercion tables are the dry-types Params tables ported verbatim;
# - " 5".to_i? is nil here, Ruby Integer(" 5") is 5 (whitespace) —
#   whitespace-padded numbers are a form-input bug either way;
# - error/output hashes are boxed in TypedParams::Any (no Object
#   generics in Crystal); the typed getters are the type-safe API.

module ActionController
  module TypedParams
    # Boxed node for the output/error trees (JSON::Any-style wrapper —
    # Crystal cannot take Object as a generic type argument).
    struct Any
      alias Type = Nil | Bool | Int32 | Int64 | Float64 | String |
                   Array(Any) | Hash(String, Any) | Parameters

      attr_reader raw : Type

      def initialize(@raw : Type)
      end

      def self.of(v) : self
        case v
        when Type then new(v)
        when Array
          # raw Array(Scalar) from Parameters — box element-wise
          new(v.map { |e| Any.of(e.as?(Parameters::Scalar) || e.to_s) })
        else new(v.to_s)
        end
      end

      def inspect(io : IO) : Nil
        raw.inspect(io)
      end

      def to_s(io : IO) : Nil
        raw.to_s(io)
      end
    end

    # Raised by `from`/`<action>_params` on validation failure; the
    # railties rescue ladder maps it to 422 with the errors as JSON.
    class Invalid < Exception
      attr_reader errors : Hash(String, Any)

      def initialize(@errors : Hash(String, Any))
        super("invalid parameters")
      end

      def to_json(io : IO) : Nil
        JSON.build(io) do |j|
          j.object do
            j.field("errors") { ::ActionController::TypedParams.dump_json(j, Any.new(@errors)) }
          end
        end
      end
    end

    # Outcome of `Call` — success flag, typed value, dry-style output
    # (coerced values; raw values for failed fields) and error tree.
    class Call(T)
      getter? success : Bool
      attr_reader value : T?
      attr_reader output : Hash(String, Any)
      attr_reader errors : Hash(String, Any)

      def initialize(@success : Bool, @value : T?, @output : Hash(String, Any),
                     @errors : Hash(String, Any))
      end
    end

    # Marker base for generated `CreateParams`-style classes.
    class Result
    end

    # One declared field — the schema tree walked by the Validator
    # (built once at boot from macro-emitted constants).
    class Field
      attr_reader key : String
      attr_reader kind : Symbol
      getter? required : Bool
      getter? nilable : Bool
      attr_reader min_size : Int32?
      attr_reader max_size : Int32?
      attr_reader gteq : Float64?
      attr_reader lteq : Float64?
      attr_reader sub : Array(Field)?

      def initialize(@key : String, @kind : Symbol, @required : Bool = false,
                     @nilable : Bool = false, @min_size : Int32? = nil,
                     @max_size : Int32? = nil, @gteq : Float64? = nil,
                     @lteq : Float64? = nil, @sub : Array(Field)? = nil)
      end

      def element_kind : Symbol
        ELEMENT_KIND_OF[kind]
      end
    end

    # Compile-time registry of declared schemas (for the OpenAPI builder).
    class SchemaEntry
      attr_reader controller : String # route key, e.g. "posts"
      attr_reader action : String     # e.g. "create"
      attr_reader fields : Array(Field)

      def initialize(@controller : String, @action : String, @fields : Array(Field))
      end
    end

    SCHEMAS = [] of SchemaEntry

    # dry-types Params coercion tables (lib/dry/types/coercions/params.rb),
    # ported verbatim.
    TRUE_VALUES  = %w(1 on On ON t true True TRUE T y yes Yes YES Y)
    FALSE_VALUES = %w(0 off Off OFF f false False FALSE F n no No NO N)

    TYPE_ERRORS = {
      :string  => "must be a string",
      :int32   => "must be an integer",
      :int64   => "must be an integer",
      :float64 => "must be a float",
      :bool    => "must be boolean",
    }

    ELEMENT_KIND_OF = {
      :array_string   => :string,
      :array_int32    => :int32,
      :array_int64    => :int64,
      :array_float64  => :float64,
      :array_bool     => :bool,
    }

    # --- validation engine -----------------------------------------------

    module Validator
      # Runs the field tree against a Parameters object; returns
      # {success, output, errors} with dry-schema semantics:
      # - missing required key → "is missing", absent from output
      # - nil / "" for filled scalars → "must be filled", raw in output
      # - nil / "" for maybe scalars → valid nil (key present in output)
      # - coercion failure → type message, raw value in output
      # - constraint failure → constraint message, coerced value in output
      # - array element failure → error keyed by element index, raw array
      def self.run(fields : Array(Field), params : Parameters)
        output = {} of String => Any
        errors = {} of String => Any
        fields.each { |f| run_field(f, params, output, errors) }
        {errors.empty?, output, errors}
      end

      def self.add_error(errors : Hash(String, Any), key : String, msg : String) : Nil
        node = errors[key]?.try(&.raw)
        if node.is_a?(Array(Any))
          node << Any.new(msg)
        else
          errors[key] = Any.new([Any.new(msg)])
        end
      end

      def self.run_field(f : Field, params : Parameters,
                         output : Hash(String, Any),
                         errors : Hash(String, Any)) : Nil
        key = f.key
        unless params.has_key?(key)
          add_error(errors, key, "is missing") if f.required?
          return
        end
        v = params[key]
        norm = v.is_a?(String) && v.empty? ? nil : v

        case f.kind
        when :string, :int32, :int64, :float64, :bool
          run_scalar(f, key, v, norm, output, errors)
        when :hash
          run_hash(f, key, v, output, errors)
        else
          run_array(f, key, v, norm, output, errors)
        end
      end

      def self.run_scalar(f : Field, key : String, v, norm,
                          output : Hash(String, Any),
                          errors : Hash(String, Any)) : Nil
        if norm.nil?
          if f.nilable?
            output[key] = Any.new(nil)
          else
            add_error(errors, key, "must be filled")
            output[key] = Any.of(v)
          end
          return
        end
        res = coerce_scalar(f.kind, norm)
        if err = res[:err]
          add_error(errors, key, err)
          output[key] = Any.of(v)
          return
        end
        val = res[:value]
        if f.kind == :string
          unless check_string_size(f, key, val, output, errors)
            output[key] = val
          end
          return
        end
        # numeric constraints — output keeps the coerced value (oracle)
        num = val.raw.as?(Float64 | Int32 | Int64)
        if g = f.gteq
          unless num && num >= g
            add_error(errors, key, "must be greater than or equal to #{fmt_num(g)}")
            output[key] = val
            return
          end
        end
        if l = f.lteq
          unless num && num <= l
            add_error(errors, key, "must be less than or equal to #{fmt_num(l)}")
            output[key] = val
            return
          end
        end
        output[key] = val
      end

      def self.check_string_size(f : Field, key : String, val : Any,
                                 output : Hash(String, Any),
                                 errors : Hash(String, Any)) : Bool
        s = val.raw.as?(String)
        if ms = f.min_size
          if s && s.size < ms
            add_error(errors, key, "size cannot be less than #{ms}")
            output[key] = val
            return true
          end
        end
        if xs = f.max_size
          if s && s.size > xs
            add_error(errors, key, "size cannot be greater than #{xs}")
            output[key] = val
            return true
          end
        end
        false
      end

      def self.run_array(f : Field, key : String, v, norm,
                         output : Hash(String, Any),
                         errors : Hash(String, Any)) : Nil
        if norm.nil?
          # ""/nil → [] (dry-types Params array coercion)
          result = [] of Any
          return if check_array_size(f, key, result, output, errors)
          output[key] = Any.new(result)
          return
        end
        unless v.is_a?(Array)
          add_error(errors, key, "must be an array")
          output[key] = Any.of(v)
          return
        end
        elem_kind = ELEMENT_KIND_OF[f.kind]
        result = [] of Any
        elem_errors = {} of String => Any
        v.each_with_index do |el, i|
          res = coerce_scalar(elem_kind, el)
          if err = res[:err]
            elem_errors[i.to_s] = Any.new([Any.new(err)])
          else
            result << res[:value]
          end
        end
        unless elem_errors.empty?
          errors[key] = Any.new(elem_errors)
          # elements coerce where possible, raw where not (oracle:
          # ["1","x",3] → [1,"x",3] with an error on "x")
          output[key] = Any.new(v.map { |e|
            res = coerce_scalar(elem_kind, e)
            res[:err] ? Any.of(e) : res[:value]
          })
          return
        end
        return if check_array_size(f, key, result, output, errors)
        output[key] = Any.new(result)
      end

      def self.check_array_size(f : Field, key : String, result : Array(Any),
                                output : Hash(String, Any),
                                errors : Hash(String, Any)) : Bool
        if ms = f.min_size
          if result.size < ms
            add_error(errors, key, "size cannot be less than #{ms}")
            output[key] = Any.new(result)
            return true
          end
        end
        if xs = f.max_size
          if result.size > xs
            add_error(errors, key, "size cannot be greater than #{xs}")
            output[key] = Any.new(result)
            return true
          end
        end
        false
      end

      def self.run_hash(f : Field, key : String, v,
                        output : Hash(String, Any),
                        errors : Hash(String, Any)) : Nil
        if v.is_a?(Parameters)
          sub_out = {} of String => Any
          sub_err = {} of String => Any
          f.sub.try(&.each { |sf| run_field(sf, v, sub_out, sub_err) })
          output[key] = Any.new(sub_out)
          errors[key] = Any.new(sub_err) unless sub_err.empty?
        else
          add_error(errors, key, "must be a hash")
          output[key] = Any.of(v)
        end
      end

      # dry-types Params scalar coercions, 1:1 with the gem tables.
      def self.coerce_scalar(kind : Symbol, v) : NamedTuple(value: Any, err: String?)
        case v
        when String
          case kind
          when :string  then {value: Any.new(v), err: nil}
          when :int32   then coerce_int(v.to_i64?, 32)
          when :int64   then coerce_int(v.to_i64?, 64)
          when :float64
            if fv = v.to_f64?
              {value: Any.new(fv), err: nil}
            else
              {value: Any.new(v), err: TYPE_ERRORS[kind]}
            end
          else               coerce_bool(v)
          end
        when Int32
          case kind
          when :string  then {value: Any.new(v), err: TYPE_ERRORS[kind]}
          when :int32   then {value: Any.new(v), err: nil}
          when :int64   then {value: Any.new(v.to_i64), err: nil}
          when :float64 then {value: Any.new(v.to_f64), err: nil}
          else               coerce_bool(v.to_s)
          end
        when Int64
          case kind
          when :string  then {value: Any.new(v), err: TYPE_ERRORS[kind]}
          when :int32   then coerce_int(v, 32)
          when :int64   then {value: Any.new(v), err: nil}
          when :float64 then {value: Any.new(v.to_f64), err: nil}
          else               coerce_bool(v.to_s)
          end
        when Float64
          case kind
          when :string  then {value: Any.new(v), err: TYPE_ERRORS[kind]}
          when :int32, :int64
            i = v.trunc.to_i64
            if kind == :int32 && (i < Int32::MIN || i > Int32::MAX)
              {value: Any.new(v), err: TYPE_ERRORS[kind]}
            else
              {value: Any.new(kind == :int32 ? i.to_i32 : i), err: nil}
            end
          when :float64 then {value: Any.new(v), err: nil}
          else               coerce_bool(v.to_s)
          end
        when Bool
          case kind
          when :bool    then {value: Any.new(v), err: nil}
          else               {value: Any.new(v), err: TYPE_ERRORS[kind]}
          end
        else
          # nil / Parameters / Array where a scalar was declared
          {value: Any.of(v), err: TYPE_ERRORS[kind]}
        end
      end

      def self.coerce_int(i : Int64?, bits : Int32) : NamedTuple(value: Any, err: String?)
        return {value: Any.new(nil), err: TYPE_ERRORS[:int32]} unless i
        if bits == 32 && (i < Int32::MIN || i > Int32::MAX)
          return {value: Any.new(i), err: TYPE_ERRORS[:int32]}
        end
        {value: Any.new(bits == 32 ? i.to_i32 : i), err: nil}
      end

      def self.coerce_bool(s : String) : NamedTuple(value: Any, err: String?)
        if TRUE_VALUES.includes?(s)
          {value: Any.new(true), err: nil}
        elsif FALSE_VALUES.includes?(s)
          {value: Any.new(false), err: nil}
        else
          {value: Any.new(s), err: TYPE_ERRORS[:bool]}
        end
      end

      def self.fmt_num(f : Float64) : String
        f == f.trunc ? f.trunc.to_i64.to_s : f.to_s
      end
    end

    # JSON emission for boxed error/output trees.
    def self.dump_json(j : JSON::Builder, node : Any) : Nil
      case raw = node.raw
      when Hash
        j.object do
          raw.each do |k, v|
            j.field(k) { dump_json(j, v) }
          end
        end
      when Array
        j.array do
          raw.each do |e|
            j.scalar(e.raw.to_s)
          end
        end
      when Nil
        j.scalar(nil)
      when Bool
        j.scalar(raw)
      when String
        j.scalar(raw)
      else
        j.scalar(raw.to_s)
      end
    end
  end
end

# --- codegen --------------------------------------------------------------
#
# `tp_class` emits one result class per schema and recurses into nested
# `do ... end` blocks via a deferred macro call (the emitted call expands
# after the enclosing class body — the standard workaround for the absence
# of recursion in the macro language itself).

macro tp_class(path, &block)
  {% exprs = block.body.is_a?(Expressions) ? block.body.expressions : [block.body] %}
  {% fields = [] of NamedTuple %}
  {% for e in exprs %}
    {% unless e.is_a?(Call) && {"required", "optional"}.includes?(e.name.stringify) %}
      {% raise "typed_params: expected `required :key, Type` or `optional :key, Type` (got `#{e}`)" %}
    {% end %}
    {% key = e.args[0].id.stringify %}
    {% opt = e.name.stringify == "optional" %}
    {% min = nil %}{% mx = nil %}{% ge = nil %}{% le = nil %}
    {% for na in (e.named_args || [] of Nil) %}
      {% if na.name.stringify == "min_size" %}    {% min = na.value %}
      {% elsif na.name.stringify == "max_size" %} {% mx = na.value %}
      {% elsif na.name.stringify == "gteq" %}     {% ge = na.value %}
      {% elsif na.name.stringify == "lteq" %}     {% le = na.value %}
      {% else %} {% raise "typed_params: unknown constraint #{na.name} (min_size/max_size/gteq/lteq)" %}
      {% end %}
    {% end %}
    {% if e.block %}
      {% sub_path = path.stringify + "::" + key.camelcase %}
      {% fields << {key: key, optional: opt, kind: :hash, tstr: sub_path, btype: sub_path, vtype: sub_path,
                    tnilable: false, getter_nilable: opt,
                    min_size: min, max_size: mx, gteq: ge, lteq: le} %}
    {% else %}
      {% tn = e.args[1].stringify %}
      {% nilable = false %}
      {% if tn == "::Union(String, ::Nil)" %}        {% base = "String" %}        {% nilable = true %}
      {% elsif tn == "::Union(Int32, ::Nil)" %}      {% base = "Int32" %}         {% nilable = true %}
      {% elsif tn == "::Union(Int64, ::Nil)" %}      {% base = "Int64" %}         {% nilable = true %}
      {% elsif tn == "::Union(Float64, ::Nil)" %}    {% base = "Float64" %}       {% nilable = true %}
      {% elsif tn == "::Union(Bool, ::Nil)" %}       {% base = "Bool" %}          {% nilable = true %}
      {% elsif tn == "String" %}                     {% base = "String" %}
      {% elsif tn == "Int32" %}                      {% base = "Int32" %}
      {% elsif tn == "Int64" %}                      {% base = "Int64" %}
      {% elsif tn == "Float64" %}                    {% base = "Float64" %}
      {% elsif tn == "Bool" %}                       {% base = "Bool" %}
      {% elsif tn == "Array(String)" %}              {% base = "Array(String)" %}
      {% elsif tn == "Array(Int32)" %}               {% base = "Array(Int32)" %}
      {% elsif tn == "Array(Int64)" %}               {% base = "Array(Int64)" %}
      {% elsif tn == "Array(Float64)" %}             {% base = "Array(Float64)" %}
      {% elsif tn == "Array(Bool)" %}                {% base = "Array(Bool)" %}
      {% else %} {% raise "typed_params: unsupported type #{tn} for :#{key} (String/Int32/Int64/Float64/Bool (+?), Array(...) or a `do` block)" %}
      {% end %}
      {% kind = nil %}{% btype = nil %}{% vtype = nil %}      {% if base == "String" %}          {% kind = :string %}        {% btype = "String" %}        {% vtype = "String" %}
      {% elsif base == "Int32" %}        {% kind = :int32 %}         {% btype = "Int32" %}         {% vtype = "Int32" %}
      {% elsif base == "Int64" %}        {% kind = :int64 %}         {% btype = "Int64" %}         {% vtype = "Int64" %}
      {% elsif base == "Float64" %}      {% kind = :float64 %}       {% btype = "Float64" %}       {% vtype = "Float64" %}
      {% elsif base == "Bool" %}         {% kind = :bool %}          {% btype = "Bool" %}          {% vtype = "Bool" %}
      {% elsif base == "Array(String)" %}  {% kind = :array_string %}   {% btype = "String" %}     {% vtype = "Array(String)" %}
      {% elsif base == "Array(Int32)" %}   {% kind = :array_int32 %}    {% btype = "Int32" %}     {% vtype = "Array(Int32)" %}
      {% elsif base == "Array(Int64)" %}   {% kind = :array_int64 %}    {% btype = "Int64" %}     {% vtype = "Array(Int64)" %}
      {% elsif base == "Array(Float64)" %} {% kind = :array_float64 %}  {% btype = "Float64" %}   {% vtype = "Array(Float64)" %}
      {% elsif base == "Array(Bool)" %}    {% kind = :array_bool %}     {% btype = "Bool" %}      {% vtype = "Array(Bool)" %}
      {% end %}
      {% fields << {key: key, optional: opt, kind: kind, tstr: tn, btype: btype, vtype: vtype,
                    tnilable: nilable, getter_nilable: (nilable || opt),
                    min_size: min, max_size: mx, gteq: ge, lteq: le} %}
    {% end %}
  {% end %}

  class {{ path.id }} < ::ActionController::TypedParams::Result
    FIELDS = begin
      fs = [] of ::ActionController::TypedParams::Field
      {% for f in fields %}
        fs << ::ActionController::TypedParams::Field.new(
          key: {{ f[:key] }}, kind: {{ f[:kind] }},
          required: {{ !f[:optional] }}, nilable: {{ f[:tnilable] }},
          {% if f[:min_size] %} min_size: {{ f[:min_size] }}, {% end %}
          {% if f[:max_size] %} max_size: {{ f[:max_size] }}, {% end %}
          {% if f[:gteq] %} gteq: {{ f[:gteq] }}.to_f64, {% end %}
          {% if f[:lteq] %} lteq: {{ f[:lteq] }}.to_f64, {% end %}
          {% if f[:kind] == :hash %} sub: {{ (f[:tstr] + "::FIELDS").id }}, {% end %}
        )
      {% end %}
      fs
    end

    {% for f in fields %}
      {% if f[:kind] == :hash %}
        @{{ f[:key].id }} : {{ f[:tstr].id }}?
      {% else %}
        @{{ f[:key].id }} : ::{{ f[:vtype].id }}?
      {% end %}
      {% if f[:getter_nilable] %}
        @present_{{ f[:key].id }} : Bool = false
      {% end %}
    {% end %}

    {% for f in fields %}
      {% key_m = f[:key].id %}
      {% if f[:kind] == :hash %}
        {% gtype = f[:tstr].id %}
      {% elsif f[:getter_nilable] %}
        {% gtype = ("::" + f[:vtype] + "?").id %}
      {% else %}
        {% gtype = ("::" + f[:vtype]).id %}
      {% end %}
      def {{ key_m }} : {{ gtype }}
        {% if f[:getter_nilable] %}
          @{{ key_m }}
        {% else %}
          @{{ key_m }}.not_nil!
        {% end %}
      end
    {% end %}

    # dry-style output hash of a valid instance (typed getters are the
    # primary API; this mirrors result.to_h for tooling/specs).
    def to_h : ::Hash(::String, ::ActionController::TypedParams::Any)
      h = {} of ::String => ::ActionController::TypedParams::Any
      {% for f in fields %}
        {% key_m = f[:key].id %}
        {% if f[:kind] == :hash %}
          {% if f[:getter_nilable] %}
            if @present_{{ key_m }} && (sub = @{{ key_m }})
              h[{{ f[:key] }}] = ::ActionController::TypedParams::Any.new(sub.to_h)
            end
          {% else %}
            h[{{ f[:key] }}] = ::ActionController::TypedParams::Any.new(
              @{{ key_m }}.not_nil!.to_h)
          {% end %}
        {% elsif [:array_string, :array_int32, :array_int64, :array_float64, :array_bool].includes?(f[:kind]) %}
          {% if f[:getter_nilable] %}
            if @present_{{ key_m }} && (arr = @{{ key_m }})
              h[{{ f[:key] }}] = ::ActionController::TypedParams::Any.new(arr.map { |e| ::ActionController::TypedParams::Any.new(e) })
            end
          {% else %}
            h[{{ f[:key] }}] = ::ActionController::TypedParams::Any.new(
              @{{ key_m }}.not_nil!.map { |e| ::ActionController::TypedParams::Any.new(e) })
          {% end %}
        {% elsif f[:getter_nilable] %}
          if @present_{{ key_m }}
            h[{{ f[:key] }}] = ::ActionController::TypedParams::Any.of(@{{ key_m }})
          end
        {% else %}
          h[{{ f[:key] }}] = ::ActionController::TypedParams::Any.of(@{{ key_m }})
        {% end %}
      {% end %}
      h
    end

    # Validate + coerce: full dry-style report without raising.
    def self.call(params : ::ActionController::Parameters)
      ok, output, errors = ::ActionController::TypedParams::Validator.run(FIELDS, params)
      value = ok ? from_output(output) : nil
      ::ActionController::TypedParams::Call(self).new(ok, value, output, errors)
    end

    # Validate and raise TypedParams::Invalid on failure (the
    # `<action>_params` helper in the controller uses this).
    def self.from(params : ::ActionController::Parameters) : self
      c = call(params)
      unless c.success?
        raise ::ActionController::TypedParams::Invalid.new(c.errors)
      end
      c.value.not_nil!
    end

    # Build the typed instance from the validator's output tree.
    def self.from_output(h : ::Hash(::String, ::ActionController::TypedParams::Any)) : self
      o = new
      o.__fill(h)
      o
    end

    protected def __fill(h : ::Hash(::String, ::ActionController::TypedParams::Any)) : self
      {% for f in fields %}
        {% key_m = f[:key].id %}
        {% if f[:kind] == :hash %}
          if sub = h[{{ f[:key] }}]?.try(&.raw.as?(::Hash(::String, ::ActionController::TypedParams::Any)))
            @{{ key_m }} = {{ f[:tstr].id }}.from_output(sub)
            {% if f[:getter_nilable] %} @present_{{ key_m }} = true {% end %}
          end
        {% elsif [:array_string, :array_int32, :array_int64, :array_float64, :array_bool].includes?(f[:kind]) %}
          {% etype = ("::" + f[:btype]).id %}
          if arr = h[{{ f[:key] }}]?.try(&.raw.as?(::Array(::ActionController::TypedParams::Any)))
            @{{ key_m }} = arr.map { |e| e.raw.as({{ etype }}) }
            {% if f[:getter_nilable] %} @present_{{ key_m }} = true {% end %}
          end
        {% elsif f[:getter_nilable] %}
          {% btype_m = ("::" + f[:btype]).id %}
          if h.has_key?({{ f[:key] }})
            @{{ key_m }} = h[{{ f[:key] }}].raw.as?({{ btype_m }})
            @present_{{ key_m }} = true
          end
        {% else %}
          {% btype_m = ("::" + f[:btype]).id %}
          @{{ key_m }} = h[{{ f[:key] }}].raw.as({{ btype_m }})
        {% end %}
      {% end %}
      self
    end
  end

  {% for e in exprs %}
    {% if e.is_a?(Call) && e.block %}
      {% sub_path = path.stringify + "::" + e.args[0].id.stringify.camelcase %}
      tp_class({{ sub_path.id }}) do
        {{ e.block.body }}
      end
    {% end %}
  {% end %}
end

module ActionController
  class Base
    # Declare the typed params schema for one or more actions:
    #
    #     typed_params(:create, :update) do
    #       required :title, String, min_size: 3
    #       optional :admin, Bool?
    #       required :author do
    #         required :name, String
    #       end
    #     end
    #
    # Generates a `<Action>Params` result class with typed getters and an
    # `<action>_params` controller helper (raises TypedParams::Invalid →
    # 422). Schemas are registered for the OpenAPI builder.
    macro typed_params(*actions, &block)
      {% for action in actions %}
        {% pc = (action.id.stringify.camelcase + "Params").id %}
        tp_class({{ pc }}) do
          {{ block.body }}
        end

        {% parts = @type.name.split("::") %}
        {% ckey = parts.last.underscore.gsub(/_controller$/, "") %}
        {% if parts.size > 1 %}
          {% ckey = parts[0...-1].map(&.underscore).join("/") + "/" + ckey %}
        {% end %}
        ::ActionController::TypedParams::SCHEMAS <<
          ::ActionController::TypedParams::SchemaEntry.new(
            {{ ckey }}, {{ action.id.stringify }}, {{ pc.id }}::FIELDS)

        def {{ (action.id.stringify + "_params").id }} : {{ pc.id }}
          {{ pc.id }}.from(params)
        end
      {% end %}
    end
  end
end
