require "spec"

# Unknown **opts keys in option-taking macros are a compile error instead
# of being silently ignored (protect_from_forgery since 0.1.3; filters,
# rescue_from and rate_limit since 0.1.4). Each fixture in
# fixtures/compile_failures/ is a self-contained file that must FAIL to
# compile with the macro's "unknown option(s)" message; the macro name is
# the fixture's basename.
describe "macro unknown option validation" do
  Dir[File.join(__DIR__, "fixtures", "compile_failures", "*.cr")].sort.each do |file|
    macro_name = File.basename(file, ".cr")

    it "#{macro_name}: unknown option is a compile error" do
      output = IO::Memory.new
      status = Process.run(
        "crystal", ["build", "--no-codegen", file],
        env: {"CRAILS_VIEWS" => File.join(__DIR__, "fixtures", "app", "views")},
        output: output, error: output
      )
      status.success?.should be_false
      message = output.to_s
      message.should contain("unknown option(s)")
      message.should contain("#{macro_name}:")
    end
  end
end
