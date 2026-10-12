# Micro-bench: typed params validation (Iteration 10) against dry-schema
# 1.13.4 (pair of bench/typed_params_bench.rb). Same schema shape as the
# oracle (5 fields: string+bounds, int+bounds, nested hash, array, maybe
# bool); valid and invalid inputs; the strong-params baseline
# (require+permit, actionpack 8.1.4) runs on both sides too.

require "../src/action_pack_cr"

class ApplicationController < ActionController::Base
end

class BenchController < ApplicationController
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
end

VALID = ActionController::Parameters.from({
  "title"  => "Title",
  "age"    => "7",
  "author" => {"name" => "Ann", "bio" => "hi"},
  "tags"   => ["a", "b"],
  "admin"  => "true",
})
INVALID = ActionController::Parameters.from({
  "title"  => "x",
  "age"    => "not_int",
  "author" => "notahash",
  "tags"   => [] of String,
  "admin"  => "maybe",
})

# warmup + correctness checks
c = BenchController::CreateParams.call(VALID)
raise "valid failed" unless c.success? && c.value.not_nil!.age == 7
c2 = BenchController::CreateParams.call(INVALID)
raise "invalid passed" unless !c2.success? && c2.errors.size == 5
v = BenchController::CreateParams.from(VALID)
raise "bad getter" unless v.author.name == "Ann"

def bench(label, seconds = 2)
  n = 0
  t0 = Time.instant
  while Time.instant - t0 < seconds.seconds
    yield
    n += 1
  end
  printf "crystal %-24s ops/sec: %.0f\n", label, n / seconds.to_f
end

bench "typed valid (call+from)" do
  BenchController::CreateParams.call(VALID)
end
bench "typed invalid (errors)" do
  BenchController::CreateParams.call(INVALID)
end
bench "typed valid (from, typed)" do
  BenchController::CreateParams.from(VALID).age
end

# strong-params baseline: require + permit on the same shape
bench "strong permit valid" do
  VALID.require("author")
  VALID.permit({"title" => [] of String, "age" => [] of String,
                "author" => [] of String, "tags" => [] of String,
                "admin" => [] of String})
end
