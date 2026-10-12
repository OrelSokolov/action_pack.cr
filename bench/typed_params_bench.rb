#!/usr/bin/env ruby
# Micro-bench: typed params validation against dry-schema 1.13.4
# (pair of bench/typed_params_bench.cr). Same schema shape as the
# oracle; valid and invalid inputs. Plain Hash inputs — dry-schema
# accepts them directly (Parameters is a Hash wrapper; actionpack
# cannot be required in the same process: dry-core pins an older
# activesupport). Strong-params baseline: typed_permit_bench.rb.

gem "dry-schema", "= 1.13.4"
require "dry-schema"

SCHEMA = Dry::Schema.Params do
  required(:title).filled(:string, min_size?: 3, max_size?: 5)
  required(:age).filled(:integer, gteq?: 2, lteq?: 10)
  required(:author).hash do
    required(:name).filled(:string)
    optional(:bio).maybe(:string, max_size?: 10)
  end
  required(:tags).value(:array, min_size?: 1) { each(:string) }
  optional(:admin).maybe(:bool)
end

VALID = {
  "title"  => "Title",
  "age"    => "7",
  "author" => {"name" => "Ann", "bio" => "hi"},
  "tags"   => ["a", "b"],
  "admin"  => "true",
}
INVALID = {
  "title"  => "x",
  "age"    => "not_int",
  "author" => "notahash",
  "tags"   => [],
  "admin"  => "maybe",
}

# warmup + correctness checks
r = SCHEMA.call(VALID)
raise "valid failed" unless r.success? && r[:age] == 7
r2 = SCHEMA.call(INVALID)
raise "invalid passed" unless !r2.success? && r2.errors.to_h.size == 5

def bench(label, seconds = 2)
  n = 0
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 < seconds
    yield
    n += 1
  end
  printf "ruby    %-24s ops/sec: %.0f\n", label, n / seconds.to_f
end

bench "typed valid (call+to_h)" do
  SCHEMA.call(VALID)
end
bench "typed invalid (errors)" do
  SCHEMA.call(INVALID)
end
bench "typed valid (filled kw)" do
  SCHEMA.call(VALID)[:age]
end
