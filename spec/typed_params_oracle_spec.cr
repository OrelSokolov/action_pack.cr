# Oracle spec: the typed-params engine must reproduce
# oracle/typed_params_expected.yml exactly (captured from dry-schema
# 1.13.4 via oracle/typed_params_cases.rb — the AGENTS.md oracle-first
# convention: same cases, same inputs, same rendered results).
#
# The DSL differs from dry-schema predicates (documented deviation);
# semantics — verdicts, coercion, output tree, error paths/messages —
# are mirrored 1:1.

require "spec"
require "../src/action_pack_cr"

TP_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/typed_params_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

# --- schemas mirroring oracle/typed_params_cases.rb ------------------------

class ApplicationController < ActionController::Base
end

class PostController < ApplicationController
  typed_params(:create) do
    required :title, String, min_size: 3, max_size: 5
    required :age, Int32, gteq: 2, lteq: 10
    required :author do
      required :name, String
      optional :bio, String?, max_size: 10
    end
    required :tags, Array(String), min_size: 1
    optional :admin, Bool?
  end

  typed_params(:simple) do
    required :id, Int32
    optional :q, String?
  end

  typed_params(:nums) do
    required :price, Float64
    required :count, Int32
    required :active, Bool
  end

  typed_params(:b) do
    required :b, Bool
  end

  typed_params(:n) do
    required :n, Int32
  end

  typed_params(:t) do
    required :t, Array(String), min_size: 1
  end

  typed_params(:each) do
    required :t, Array(String)
  end

  typed_params(:s) do
    required :s, String
  end

  typed_params(:st) do
    required :t, String
  end

  typed_params(:h) do
    required :h do
      required :k, String
    end
  end

  typed_params(:ns) do
    required :ns, Array(Int32)
  end

  typed_params(:x) do
    required :x, Int32?
  end

  typed_params(:optx) do
    optional :x, Int32?
  end

  typed_params(:optn) do
    optional :n, Int32?
  end

  typed_params(:optb) do
    optional :b, Bool?
  end

  typed_params(:f) do
    required :f, Float64
  end
end

def tp_params(h : Hash) : ActionController::Parameters
  ActionController::Parameters.from(h)
end

def tp_render(v) : String
  case v
  when Hash
    "H{" + v.map { |k, val| "#{k}=>#{tp_render(val)}" }.sort.join(",") + "}"
  when Array
    "A[#{v.map { |e| render(e) }.join(",")}]"
  when ActionController::Parameters then tp_render(v.to_unsafe_h)
  when String                      then v.inspect
  else                                  v.inspect
  end
end

def any_render(v : ActionController::TypedParams::Any) : String
  case raw = v.raw
  when Hash(String, ActionController::TypedParams::Any)
    "H{" + raw.map { |k, val| "#{k}=>#{any_render(val)}" }.sort.join(",") + "}"
  when Array(ActionController::TypedParams::Any)
    "A[#{raw.map { |e| any_render(e) }.join(",")}]"
  when ActionController::Parameters
    "H{" + raw.to_unsafe_h.map { |k, val| "#{k}=>#{tp_render(val)}" }.sort.join(",") + "}"
  when String then raw.inspect
  else            raw.inspect
  end
end

# Renders the [success?, output, errors] triple like the Ruby oracle.
def call_result(call) : String
  out = any_render(ActionController::TypedParams::Any.new(call.output))
  err = any_render(ActionController::TypedParams::Any.new(call.errors))
  "A[#{call.success?},#{out},#{err}]"
end

def run_schema(klass, input) : String
  call = klass.call(tp_params(input))
  call_result(call)
end

# --- the same cases as oracle/typed_params_cases.rb ------------------------

def tp_run_case(id : String) : String
  case id
  when "tp_post_valid"
    run_schema(PostController::CreateParams, {"title" => "Title", "age" => "7",
      "author" => {"name" => "Ann"}, "tags" => ["a", "b"], "admin" => "true"})
  when "tp_post_valid_native"
    run_schema(PostController::CreateParams, {"title" => "Hey", "age" => 7,
      "author" => {"name" => "Ann", "bio" => "hi"}, "tags" => ["x"], "admin" => false})
  when "tp_post_drops_unknown"
    run_schema(PostController::CreateParams, {"title" => "Title", "age" => "5",
      "author" => {"name" => "A", "zz" => 1}, "tags" => ["t"], "secret" => "nope"})
  when "tp_simple_valid"          then run_schema(PostController::SimpleParams, {"id" => "7", "q" => "find"})
  when "tp_simple_no_optional"    then run_schema(PostController::SimpleParams, {"id" => "7"})
  when "tp_simple_sym_keys"       then run_schema(PostController::SimpleParams, {"id" => "7", "q" => ""})
  when "tp_nums_coerce"           then run_schema(PostController::NumsParams, {"price" => "2.5", "count" => "3", "active" => "1"})
  when "tp_nums_int_to_float"     then run_schema(PostController::NumsParams, {"price" => 2, "count" => 4, "active" => false})
  when "tp_bool_strings_true"     then run_schema(PostController::BParams, {"b" => "yes"})
  when "tp_bool_strings_false"    then run_schema(PostController::BParams, {"b" => "off"})
  when "tp_bool_bad"              then run_schema(PostController::BParams, {"b" => "maybe"})
  when "tp_missing_all"           then run_schema(PostController::CreateParams, {} of String => String)
  when "tp_missing_nested_key"    then run_schema(PostController::CreateParams, {"title" => "Hi", "age" => "5", "author" => {} of String => String, "tags" => ["t"]})
  when "tp_empty_string_filled_int" then run_schema(PostController::NParams, {"n" => ""})
  when "tp_empty_string_maybe"    then run_schema(PostController::OptnParams, {"n" => ""})
  when "tp_empty_string_maybe_nested"
    run_schema(PostController::CreateParams, {"title" => "Hi", "age" => "5",
      "author" => {"name" => "A", "bio" => ""}, "tags" => ["t"]})
  when "tp_empty_array_not_filled" then run_schema(PostController::TParams, {"t" => [] of String})
  when "tp_int_float_str"         then run_schema(PostController::NParams, {"n" => "1.5"})
  when "tp_float_bad"             then run_schema(PostController::NumsParams, {"price" => "1.5x", "count" => "3", "active" => "true"})
  when "tp_str_on_hash"           then run_schema(PostController::StParams, {"t" => {"a" => 1}})
  when "tp_hash_on_array"         then run_schema(PostController::HParams, {"h" => [1]})
  when "tp_array_on_str"
    run_schema(PostController::CreateParams, {"title" => "Hi", "age" => "5",
      "author" => {"name" => "A"}, "tags" => "notarray"})
  when "tp_str_min_size"
    run_schema(PostController::CreateParams, {"title" => "ab", "age" => "5", "author" => {"name" => "A"}, "tags" => ["t"]})
  when "tp_str_max_size"
    run_schema(PostController::CreateParams, {"title" => "abcdef", "age" => "5", "author" => {"name" => "A"}, "tags" => ["t"]})
  when "tp_int_gteq"
    run_schema(PostController::CreateParams, {"title" => "abc", "age" => "1", "author" => {"name" => "A"}, "tags" => ["t"]})
  when "tp_int_lteq"
    run_schema(PostController::CreateParams, {"title" => "abc", "age" => "11", "author" => {"name" => "A"}, "tags" => ["t"]})
  when "tp_bio_max_size"
    run_schema(PostController::CreateParams, {"title" => "abc", "age" => "5",
      "author" => {"name" => "A", "bio" => "0123456789X"}, "tags" => ["t"]})
  when "tp_array_min_size"
    run_schema(PostController::CreateParams, {"title" => "abc", "age" => "5", "author" => {"name" => "A"}, "tags" => [] of String})
  when "tp_each_type_error"
    run_schema(PostController::CreateParams, {"title" => "abc", "age" => "5",
      "author" => {"name" => "A"}, "tags" => ["ok", 1, true]})
  when "tp_each_int"
    run_schema(PostController::NsParams, {"ns" => ["1", "x", 3]})
  when "tp_multi_errors"
    run_schema(PostController::CreateParams, {"title" => "", "age" => "x",
      "author" => "notahash", "tags" => [] of String})
  when "tp_str_from_int"          then run_schema(PostController::SParams, {"s" => 5})
  when "tp_int_from_float"        then run_schema(PostController::NParams, {"n" => 2.5})
  when "tp_int_from_bool"         then run_schema(PostController::NParams, {"n" => true})
  when "tp_int_plus_minus"        then run_schema(PostController::NParams, {"n" => "+5"})
  when "tp_float_exp_notation"
    run_schema(PostController::FParams, {"f" => "1e3"})
  when "tp_array_from_empty_str"  then run_schema(PostController::EachParams, {"t" => ""})
  when "tp_bool_y_n"              then run_schema(PostController::BParams, {"b" => "y"})
  when "tp_bool_native_int"       then run_schema(PostController::BParams, {"b" => 1})
  when "tp_maybe_bool_empty"      then run_schema(PostController::OptbParams, {"b" => ""})
  when "tp_required_maybe_missing" then run_schema(PostController::XParams, {} of String => String)
  when "tp_required_nilable_nil"  then run_schema(PostController::XParams, {"x" => nil})
  else
    return "UNKNOWN-CASE:#{id}"
  end
end

describe "typed params oracle (dry-schema 1.13.4)" do
  TP_EXPECTED.each do |id, expected|
    it id do
      tp_run_case(id).should eq(expected)
    end
  end
end

# --- unit-level: typed getters, Invalid, controller helper -----------------

describe "typed params units" do
  it "typed getters are compile-checked accessors" do
    v = PostController::CreateParams.from(tp_params({"title" => "Title", "age" => "7",
      "author" => {"name" => "Ann"}, "tags" => ["a", "b"]}))
    v.title.should eq("Title")
    v.age.should eq(7)
    v.author.name.should eq("Ann")
    v.tags.should eq(["a", "b"])
    v.admin.should be_nil
    typeof(v.title).should eq(String)
    typeof(v.age).should eq(Int32)
    typeof(v.author.name).should eq(String)
    typeof(v.tags).should eq(Array(String))
    typeof(v.admin).should eq(Bool | Nil)
  end

  it "from raises Invalid with the error tree" do
    ex = expect_raises(ActionController::TypedParams::Invalid) do
      PostController::CreateParams.from(tp_params({"title" => ""}))
    end
    ex.errors["title"].raw.as(Array).map(&.raw.to_s).should eq(["must be filled"])
    ex.to_json.should contain("must be filled")
  end

  it "to_h mirrors the dry output tree" do
    v = PostController::SimpleParams.from(tp_params({"id" => "7", "q" => ""}))
    h = v.to_h
    h.keys.sort.should eq(["id", "q"])
    h["id"].raw.should eq(7)
    h["q"].raw.should be_nil
  end

  it "optional absent stays out of to_h" do
    v = PostController::SimpleParams.from(tp_params({"id" => "1"}))
    v.to_h.keys.should eq(["id"])
    v.q.should be_nil
  end

  it "registers schemas for the OpenAPI builder" do
    entry = ActionController::TypedParams::SCHEMAS.find { |s|
      s.controller == "post" && s.action == "create"
    }
    entry.should_not be_nil
    entry.not_nil!.fields.map(&.key).should eq(["title", "age", "author", "tags", "admin"])
  end
end
