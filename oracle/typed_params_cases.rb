# Oracle cases for ActionController::TypedParams (Iteration 10).
#
# Run against the ORIGINAL gem (dry-schema 1.13.4 — the industry-standard
# typed params/validation library for Ruby):
#   ruby oracle/typed_params_cases.rb > oracle/typed_params_expected.yml
#
# Each line: "<case_id>\t<rendered [success?, output, errors]>".
# The Crystal port (src/typed_params.cr) must reproduce every line with a
# schema declared through the `typed_params` DSL (documented deviation:
# DSL syntax differs — dry-schema predicates vs typed Crystal declarations;
# semantics — coercion, verdicts, error paths/messages — are mirrored 1:1).
gem "dry-schema", "= 1.13.4"
require "dry-schema"

def render(v)
  case v
  when Hash then "H{" + v.sort_by { |k, _| k.to_s }.map { |k, val| "#{k.to_s}=>#{render(val)}" }.join(",") + "}"
  when Array then "A[#{v.map { |e| render(e) }.join(",")}]"
  when true, false, Integer, Float, nil then v.inspect
  when String then v.inspect
  else v.inspect
  end
end

def case_run(id)
  result = yield
  puts "#{id}\t#{render([result.success?, result.to_h, result.errors.to_h])}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

# --- schemas under test ---------------------------------------------------

POST = Dry::Schema.Params do
  required(:title).filled(:string, min_size?: 3, max_size?: 5)
  required(:age).filled(:integer, gteq?: 2, lteq?: 10)
  required(:author).hash do
    required(:name).filled(:string)
    optional(:bio).maybe(:string, max_size?: 10)
  end
  required(:tags).value(:array, min_size?: 1) { each(:string) }
  optional(:admin).maybe(:bool)
end

SIMPLE = Dry::Schema.Params do
  required(:id).filled(:integer)
  optional(:q).maybe(:string)
end

NUMS = Dry::Schema.Params do
  required(:price).filled(:float)
  required(:count).filled(:integer)
  required(:active).filled(:bool)
end

# --- happy paths ----------------------------------------------------------

case_run("tp_post_valid") do
  POST.call("title" => "Title", "age" => "7",
            "author" => {"name" => "Ann"}, "tags" => ["a", "b"], "admin" => "true")
end
case_run("tp_post_valid_native") do
  POST.call(title: "Hey", age: 7, author: {name: "Ann", bio: "hi"},
            tags: ["x"], admin: false)
end
case_run("tp_post_drops_unknown") do
  POST.call("title" => "Title", "age" => "5", "author" => {"name" => "A", "zz" => 1},
            "tags" => ["t"], "secret" => "nope")
end
case_run("tp_simple_valid")    { SIMPLE.call("id" => "7", "q" => "find") }
case_run("tp_simple_no_optional") { SIMPLE.call("id" => "7") }
case_run("tp_simple_sym_keys") { SIMPLE.call(id: "7", q: "") }

# --- coercion ---------------------------------------------------------------

case_run("tp_nums_coerce") { NUMS.call("price" => "2.5", "count" => "3", "active" => "1") }
case_run("tp_nums_int_to_float") { NUMS.call(price: 2, count: 4, active: false) }
case_run("tp_bool_strings_true") do
  Dry::Schema.Params { required(:b).filled(:bool) }.call("b" => "yes")
end
case_run("tp_bool_strings_false") do
  Dry::Schema.Params { required(:b).filled(:bool) }.call("b" => "off")
end
case_run("tp_bool_bad") do
  Dry::Schema.Params { required(:b).filled(:bool) }.call("b" => "maybe")
end

# --- missing / empty -------------------------------------------------------

case_run("tp_missing_all") { POST.call({}) }
case_run("tp_missing_nested_key") { POST.call("title" => "Hi", "age" => "5", "author" => {}, "tags" => ["t"]) }
case_run("tp_empty_string_filled_int") do
  Dry::Schema.Params { required(:n).filled(:integer) }.call("n" => "")
end
case_run("tp_empty_string_maybe") do
  Dry::Schema.Params { optional(:n).maybe(:integer) }.call("n" => "")
end
case_run("tp_empty_string_maybe_nested") { POST.call("title" => "Hi", "age" => "5", "author" => {"name" => "A", "bio" => ""}, "tags" => ["t"]) }
case_run("tp_empty_array_not_filled") do
  Dry::Schema.Params { required(:t).value(:array, min_size?: 1) { each(:string) } }.call("t" => [])
end

# --- wrong types ------------------------------------------------------------

case_run("tp_int_float_str") do
  Dry::Schema.Params { required(:n).filled(:integer) }.call("n" => "1.5")
end
case_run("tp_float_bad") { NUMS.call("price" => "1.5x", "count" => "3", "active" => "true") }
case_run("tp_str_on_hash") do
  Dry::Schema.Params { required(:t).filled(:string) }.call("t" => {"a" => 1})
end
case_run("tp_hash_on_array") do
  Dry::Schema.Params { required(:h).hash { required(:k).filled(:string) } }.call("h" => [1])
end
case_run("tp_array_on_str") { POST.call("title" => "Hi", "age" => "5", "author" => {"name" => "A"}, "tags" => "notarray") }

# --- constraints ------------------------------------------------------------

case_run("tp_str_min_size") { POST.call("title" => "ab", "age" => "5", "author" => {"name" => "A"}, "tags" => ["t"]) }
case_run("tp_str_max_size") { POST.call("title" => "abcdef", "age" => "5", "author" => {"name" => "A"}, "tags" => ["t"]) }
case_run("tp_int_gteq")     { POST.call("title" => "abc", "age" => "1", "author" => {"name" => "A"}, "tags" => ["t"]) }
case_run("tp_int_lteq")     { POST.call("title" => "abc", "age" => "11", "author" => {"name" => "A"}, "tags" => ["t"]) }
case_run("tp_bio_max_size") { POST.call("title" => "abc", "age" => "5", "author" => {"name" => "A", "bio" => "0123456789X"}, "tags" => ["t"]) }
case_run("tp_array_min_size") { POST.call("title" => "abc", "age" => "5", "author" => {"name" => "A"}, "tags" => []) }

# --- array elements ---------------------------------------------------------

case_run("tp_each_type_error") do
  POST.call("title" => "abc", "age" => "5", "author" => {"name" => "A"}, "tags" => ["ok", 1, true])
end
case_run("tp_each_int") do
  Dry::Schema.Params { required(:ns).value(:array) { each(:integer) } }.call("ns" => ["1", "x", 3])
end

# --- multiple errors on one schema ------------------------------------------

case_run("tp_multi_errors") do
  POST.call("title" => "", "age" => "x", "author" => "notahash", "tags" => [])
end

# --- pinned coercion edges (dry-types Params tables) ------------------------

case_run("tp_str_from_int") do
  Dry::Schema.Params { required(:s).filled(:string) }.call("s" => 5)
end
case_run("tp_int_from_float") do
  Dry::Schema.Params { required(:n).filled(:integer) }.call("n" => 2.5)
end
case_run("tp_int_from_bool") do
  Dry::Schema.Params { required(:n).filled(:integer) }.call("n" => true)
end
case_run("tp_int_plus_minus") do
  Dry::Schema.Params { required(:n).filled(:integer) }.call("n" => "+5")
end
case_run("tp_float_exp_notation") do
  Dry::Schema.Params { required(:f).filled(:float) }.call("f" => "1e3")
end
case_run("tp_array_from_empty_str") do
  Dry::Schema.Params { required(:t).value(:array) { each(:string) } }.call("t" => "")
end
case_run("tp_bool_y_n") do
  Dry::Schema.Params { required(:b).filled(:bool) }.call("b" => "y")
end
case_run("tp_bool_native_int") do
  Dry::Schema.Params { required(:b).filled(:bool) }.call("b" => 1)
end
case_run("tp_maybe_bool_empty") do
  Dry::Schema.Params { optional(:b).maybe(:bool) }.call("b" => "")
end
case_run("tp_required_maybe_missing") do
  Dry::Schema.Params { required(:x).maybe(:integer) }.call({})
end
case_run("tp_required_nilable_nil") do
  Dry::Schema.Params { required(:x).maybe(:integer) }.call("x" => nil)
end
