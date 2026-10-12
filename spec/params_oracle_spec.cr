# Oracle spec: the Crystal port must reproduce oracle/params_expected.yml
# exactly (captured from actionpack 8.1.4 via oracle/params_cases.rb).
#
# NOTE: the case table is built at runtime, not as a const — a Crystal
# 1.21 compiler bug crashes codegen on lambdas stored in consts that
# call mixed-splat methods (`permit(*filters, **nested)`).

require "spec"
require "../src/action_pack_cr"

EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/params_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

def build_params : ActionController::Parameters
  ActionController::Parameters.from({
    "post" => {
      "title"  => "Hi",
      "body"   => "Words",
      "tags"   => ["a", "b"],
      "author" => {"name" => "Ann", "age" => "33"},
      "secret" => "nope",
    },
    "id"     => "7",
    "commit" => "Save",
  })
end

def render(v) : String
  case v
  when Hash
    "H{" + v.map { |k, val| "#{k}=>#{render(val)}" }.sort.join(",") + "}"
  when Array
    "A[#{v.map { |e| render(e) }.join(",")}]"
  when ActionController::Parameters then render(v.to_unsafe_h)
  when String                      then v.inspect
  else                                  v.inspect
  end
end

def render_result(v) : String
  render(v)
rescue e : ActionController::ParameterMissing | ActionController::UnfilteredParameters
  "raise:#{e.class.name}"
end

# Returns id -> rendered result (runs the same expressions as
# oracle/params_cases.rb). Built per call: some cases mutate params.
def run_case(id : String) : String?
  p = build_params
  begin
    case id
  when "p_index_str"          then render_result(p["post"].as(ActionController::Parameters)["title"])
  when "p_index_sym"          then render_result(p[:post].as(ActionController::Parameters)[:title])
  when "p_index_missing"      then render_result(p[:nope])
  when "p_dig"                then render_result(p.dig(:post, :author, :name))
  when "p_fetch"              then render_result(p.fetch(:id))
  when "p_fetch_default"      then render_result(p.fetch(:missing, "dflt"))
  when "p_slice"              then render_result(p.slice(:id, :commit))
  when "p_keys"               then render_result(p.keys.sort)
  when "p_has_key"            then render_result(p.has_key?(:post))
  when "p_require"            then render_result(p.require(:post)[:title])
  when "p_require_permit"     then render_result(p.require(:post).permit(:title, :body))
  when "p_require_missing"    then render_result(p.require(:nope))
  when "p_permit_flat"        then render_result(p.require(:post).permit(:title, :body))
  when "p_permit_drops"       then render_result(p.require(:post).permit(:title))
  when "p_permit_array"       then render_result(p.require(:post).permit({"tags" => [] of String}))
  when "p_permit_nested"      then render_result(p.require(:post).permit(:title, {"author" => [:name]}))
  when "p_permit_all"         then sub = p.require(:post); sub.permit!; render_result(sub)
  when "p_permit_scalar"      then render_result(p.permit(:id, :commit))
  when "p_to_h_unpermitted"   then render_result(p.to_h)
  when "p_to_h_permitted"     then render_result(p.require(:post).permit(:title).to_h)
  when "p_to_unsafe_h"        then render_result(p.slice("id").to_unsafe_h)
  when "p_expect"             then render_result(p.expect({"post" => [:title, :body]}))
  when "p_expect_array"       then render_result(p.expect({"post" => [:tags]}))
  when "p_expect_missing"     then render_result(p.expect({"nope" => [:x]}))
  when "p_nested_string_keys"
    q = ActionController::Parameters.from({:post => {:title => "T"}})
    render_result(q.require(:post).permit(:title).to_h)
  when "p_array_value"
    q = ActionController::Parameters.from({:ids => ["1", "2"]})
    render_result(q.permit({"ids" => [] of String}))
  when "p_permit_empty_hash"
    q = ActionController::Parameters.from({:prefs => {:a => 1}})
    render_result(q.permit({"prefs" => {} of String => String}))
    else
      nil
    end
  end
rescue e : ActionController::ParameterMissing | ActionController::UnfilteredParameters
  "raise:#{e.class.name}"
end

describe "ActionController::Parameters oracle (actionpack 8.1.4)" do
  EXPECTED.each do |id, expected|
    it id do
      result = run_case(id)
      result.should_not be_nil, "case #{id} not mirrored in spec"
      result.should eq(expected), "#{id}: expected #{expected.inspect}, got #{result.inspect}"
    end
  end

  it "mirrors every oracle case" do
    EXPECTED.each_key do |id|
      run_case(id).should_not be_nil, "case #{id} missing a branch"
    end
  end
end
