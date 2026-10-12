require "json"

# ActionController::Parameters — port of strong parameters
# (actionpack 8.1.4), byte-exact on the oracle (oracle/params_expected.yml).
#
# Key access is indifferent String/Symbol (everything is normalized to
# String keys internally). Ruby's `permit(a: [:b])` keyword-hash syntax
# maps 1:1 to Crystal named arguments: `permit(a: [:b])`.
#
# Filter semantics (as in Rails):
# - `permit(:a, :b)` — scalar keys only
# - `permit(tags: [])` — empty array: array-of-scalars key
# - `permit(post: [:title, {author: [:name]}])` — non-empty array: nested
#   hash key filtered by the listed keys (hash elements recurse)
# - `permit(prefs: {})` — empty hash: allow the whole nested hash

module ActionController
  class ParameterMissing < Exception
    getter param : String

    def initialize(@param : String, message = nil)
      super(message || "param is missing or the value is empty or invalid: #{param}")
    end
  end

  class UnfilteredParameters < Exception
    def initialize(message = "attempted to use unpermitted parameters")
      super(message)
    end
  end

  class Parameters
    alias Scalar = String | Int32 | Int64 | Float64 | Bool | Nil
    alias Value = Scalar | Array(Scalar) | Parameters

    getter parameters : Hash(String, Value)
    property? permitted : Bool

    def initialize(@parameters : Hash(String, Value) = {} of String => Value,
                   @permitted : Bool = false)
    end

    def self.from(raw : Hash) : self
      converted = {} of String => Value
      raw.each do |k, v|
        converted[k.to_s] = convert(v)
      end
      new(converted)
    end

    private def self.convert(v) : Value
      case v
      when Parameters then v
      when Scalar   then v.as(Scalar)
      when Array    then v.map { |e| (e.as?(Scalar) || e.to_s).as(Scalar) }
      when Hash     then from(v.as(Hash))
      when JSON::Any
        raw = v.raw
        case raw
        when Scalar then raw.as(Scalar)
        when Array  then raw.map { |e| (e.as?(Scalar) || e.to_s).as(Scalar) }
        when Hash   then from(raw.as(Hash))
        else             v.to_s
        end
      else v.to_s
      end
    end

    # --- access -----------------------------------------------------

    def [](key : String | Symbol) : Value?
      @parameters[key.to_s]?
    end

    def []?(key : String | Symbol) : Value?
      @parameters[key.to_s]?
    end

    def []=(key : String | Symbol, value : Value) : Value
      @parameters[key.to_s] = value
    end

    def has_key?(key : String | Symbol) : Bool
      @parameters.has_key?(key.to_s)
    end

    def key?(key : String | Symbol) : Bool
      has_key?(key)
    end

    def keys : Array(String)
      @parameters.keys
    end

    def fetch(key : String | Symbol, default = nil)
      @parameters.fetch(key.to_s, default)
    end

    def dig(key : String | Symbol, *rest : String | Symbol) : Value?
      node = self[key]
      return nil if node.nil?
      rest.each do |k|
        sub = node.as?(Parameters) || return nil
        node = sub[k] || return nil
      end
      node
    end

    def slice(*keys : String | Symbol) : Parameters
      filtered = {} of String => Value
      keys.each do |k|
        filtered[k.to_s] = @parameters[k.to_s] if @parameters[k.to_s]?
      end
      Parameters.new(filtered, @permitted)
    end

    def empty? : Bool
      @parameters.empty?
    end

    def size : Int32
      @parameters.size
    end

    private def first_value? : Value
      @parameters.first_value
    end

    # --- require / permit --------------------------------------------

    # require(:post) returns the nested parameters themselves (as in
    # Rails); require([:a, :b]) returns a Parameters holding those keys.
    def require(key : String | Symbol | Array(String | Symbol)) : Parameters
      keys = key.is_a?(Array) ? key : [key]
      if keys.size == 1
        k = keys.first
        value = self[k]
        raise ParameterMissing.new(k.to_s) if value.nil? || (value.is_a?(Parameters) && value.empty?)
        if sub = value.as?(Parameters)
          sub
        else
          Parameters.new({k.to_s => value.as(Value)})
        end
      else
        required = Parameters.new({} of String => Value)
        keys.each do |k|
          value = self[k]
          raise ParameterMissing.new(k.to_s) if value.nil? || (value.is_a?(Parameters) && value.empty?)
          required[k.to_s] = value.as(Value)
        end
        required
      end
    end

    # `permit(:title, {"author" => [:name]})` — nested/array filters are
    # passed as a Hash argument instead of Ruby keyword syntax
    # (documented deviation: Crystal can't take heterogeneous keyword
    # splats here).
    def permit(*filters) : Parameters
      params = permit_filters(filters.to_a)
      params.permitted = true
      params
    end

    def permit! : self
      @parameters.each_value do |v|
        v.as?(Parameters).try(&.permit!)
      end
      @permitted = true
      self
    end

    # permit + require: every filtered key must be present and non-empty.
    # `expect({"post" => [:title, :body]})` — same Hash-argument style
    # as permit.
    def expect(*filters) : Parameters | Value
      params = permit_filters(filters.to_a)
      params.permitted = true
      string_keys = [] of String
      filters.to_a.each do |f|
        case f
        when String, Symbol then string_keys << f.to_s
        when Hash           then f.each_key { |k| string_keys << k.to_s }
        end
      end
      values = params.require(string_keys)
      values.size == 1 ? values.parameters.first_value? : values
    end

    def to_h : Hash(String, Value)
      raise UnfilteredParameters.new unless @permitted
      @parameters.dup
    end

    def to_unsafe_h : Hash(String, Value)
      @parameters.dup
    end

    def to_s(io : IO) : Nil
      to_unsafe_h.to_s(io)
    end

    # --- permit internals ---------------------------------------------

    private def permit_filters(filters : Array) : Parameters
      filtered = Parameters.new
      filters.each do |f|
        case f
        when String, Symbol
          k = f.to_s
          if v = @parameters[k]?
            filtered[k] = v unless v.is_a?(Parameters) || v.is_a?(Array)
          end
        when Hash
          f.each { |k, spec| apply_spec(k.to_s, spec, filtered) }
        end
      end
      filtered
    end

    protected def apply_spec(k : String, spec, filtered : Parameters) : Nil
      param = @parameters[k]?
      case spec
      when Array
        if spec.empty?
          filtered[k] = param if param.is_a?(Array)
        elsif sub = param.as?(Parameters)
          filtered[k] = sub.permit_list(spec)
        end
      when Hash
        if spec.empty?
          if sub = param.as?(Parameters)
            filtered[k] = sub.permit_all_nested
          end
        elsif sub = param.as?(Parameters)
          filtered[k] = sub.permit_pairs(spec)
        end
      end
    end

    protected def permit_list(list : Array) : Parameters
      filtered = Parameters.new
      scalar_keys = [] of String
      list.each do |item|
        case item
        when Symbol, String then scalar_keys << item.to_s
        when Hash
          item.each { |ik, spec| apply_spec(ik.to_s, spec, filtered) }
        end
      end
      keep_scalars(scalar_keys, filtered)
    end

    protected def permit_pairs(spec) : Parameters
      filtered = Parameters.new
      spec.each do |k, sub_spec|
        apply_spec(k.to_s, sub_spec, filtered)
      end
      filtered
    end

    protected def keep_scalars(scalar_keys : Array(String), filtered : Parameters) : Parameters
      @parameters.each do |k, v|
        next unless scalar_keys.includes?(k)
        filtered[k] = v unless v.is_a?(Parameters) || v.is_a?(Array)
      end
      filtered
    end

    protected def permit_all_nested : Parameters
      filtered = Parameters.new
      @parameters.each do |k, v|
        filtered[k] = v.as?(Parameters).try(&.permit_all_nested) || v
      end
      filtered
    end
  end
end