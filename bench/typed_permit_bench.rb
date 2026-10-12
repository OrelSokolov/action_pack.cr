#!/usr/bin/env ruby
# Strong-params baseline (require+permit, actionpack 8.1.4) — pair of
# the same case in bench/typed_params_bench.cr. Runs apart from
# typed_params_bench.rb: dry-schema and actionpack 8.1.4 cannot be
# activated in one process (activesupport version pin).

gem "actionpack", "= 8.1.4"
require "action_controller"

VALID = ActionController::Parameters.new({
  "title"  => "Title",
  "age"    => "7",
  "author" => {"name" => "Ann", "bio" => "hi"},
  "tags"   => ["a", "b"],
  "admin"  => "true",
})

# warmup + correctness check
VALID.require(:author).permit(:name, :bio)

n = 0
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
while Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 < 2
  VALID.require(:author)
  VALID.permit(:title, :age, :author, :tags, :admin)
  n += 1
end
printf "ruby    %-24s ops/sec: %.0f\n", "strong permit valid", n / 2.0
