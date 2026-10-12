# Synthetic oracle cases for ActionController::Parameters (Iteration 3).
#
# Run against the ORIGINAL gem:
#   ruby oracle/params_cases.rb > oracle/params_expected.yml
#
# Each line: "<case_id>\t<rendered result>". Mirrored 1:1 in
# spec/params_oracle_spec.cr; the Crystal port must reproduce
# params_expected.yml exactly (captured from actionpack 8.1.4).
gem "actionpack", "= 8.1.4"
require "action_controller"

def render(v)
  case v
  when Hash then "H{" + v.sort_by { |k, _| k.to_s }.map { |k, val| "#{k}=>#{render(val)}" }.join(",") + "}"
  when Array then "A[#{v.map { |e| render(e) }.join(",")}]"
  when ActionController::Parameters then render(v.to_unsafe_h)
  when true, false, Integer, Float, nil then v.inspect
  when String then v.inspect
  else v.inspect
  end
end

def case_run(id)
  puts "#{id}\t#{render(yield)}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

P = ActionController::Parameters.new({
  "post" => {
    "title"  => "Hi",
    "body"   => "Words",
    "tags"   => ["a", "b"],
    "author" => {"name" => "Ann", "age" => "33"},
    "secret" => "nope",
  },
  "id"      => "7",
  "commit"  => "Save",
})

case_run("p_index_str")     { P["post"]["title"] }
case_run("p_index_sym")     { P[:post][:title] }
case_run("p_index_missing") { P[:nope] }
case_run("p_dig")           { P.dig(:post, :author, :name) }
case_run("p_fetch")         { P.fetch(:id) }
case_run("p_fetch_default") { P.fetch(:missing, "dflt") }
case_run("p_slice")         { P.slice(:id, :commit) }
case_run("p_keys")          { P.keys.sort }
case_run("p_has_key")       { P.has_key?(:post) }
case_run("p_require")       { P.require(:post)[:title] }
case_run("p_require_permit") { P.require(:post).permit(:title, :body) }
case_run("p_require_missing") { P.require(:nope) }
case_run("p_permit_flat")   { P.require(:post).permit(:title, :body) }
case_run("p_permit_drops")  { P.require(:post).permit(:title) }
case_run("p_permit_array")  { P.require(:post).permit(tags: []) }
case_run("p_permit_nested") { P.require(:post).permit(:title, author: [:name]) }
case_run("p_permit_all")    { P.require(:post).permit!; P.require(:post) }
case_run("p_permit_scalar") { P.permit(:id, :commit) }
case_run("p_to_h_unpermitted") { P.to_h }
case_run("p_to_h_permitted") { P.require(:post).permit(:title).to_h }
case_run("p_to_unsafe_h")   { P.slice("id").to_unsafe_h }
case_run("p_expect")        { P.expect(post: [:title, :body]) }
case_run("p_expect_array")  { P.expect(post: [:tags]) }
case_run("p_expect_missing") { P.expect(nope: [:x]) }
case_run("p_nested_string_keys") do
  q = ActionController::Parameters.new(post: {title: "T"})
  q.require(:post).permit(:title).to_h
end
case_run("p_array_value") do
  q = ActionController::Parameters.new(ids: ["1", "2"])
  q.permit(ids: [])
end
case_run("p_permit_empty_hash") do
  q = ActionController::Parameters.new(prefs: {a: 1})
  q.permit(prefs: {})
end
