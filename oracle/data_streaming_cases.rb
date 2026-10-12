# Oracle cases for ActionController::DataStreaming (send_data /
# send_file, P2 slot of action_pack).
#
# Run against the ORIGINAL gem:
#   ruby oracle/data_streaming_cases.rb > oracle/data_streaming_expected.yml
#
# Each line: "<case_id>\t<value>" (newlines escaped as \n). Mirrored
# 1:1 in railties.cr/spec/data_streaming_spec.cr. Bare controllers +
# ShowExceptions, like the CSRF/rate_limit oracles; a real temp file
# backs the send_file cases.

gem "actionpack", "= 8.1.4"
gem "rack", "~> 3"
require "action_controller"
require "fileutils"

def render(v)
  case v
  when String then v.gsub("\n", "\\n")
  else v.inspect
  end
end

def case_run(id)
  puts "#{id}\t#{render(yield)}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

DIR = File.expand_path("data_streaming_fixture", __dir__)
FileUtils.rm_rf(DIR)
FileUtils.mkdir_p(DIR)
File.write(File.join(DIR, "notes.txt"), "file body\n")
File.write(File.join(DIR, "report.pdf"), "%PDF-fake")
File.write(File.join(DIR, "data.bin"), "\x00\x01binary")
File.write(File.join(DIR, "страница.html"), "<h1>привет</h1>")

class DataController < ActionController::Base
  def data_default
    send_data("hello")
  end

  def data_filename
    send_data("pdf!", filename: "report.pdf")
  end

  def data_filename_utf8
    send_data("привет", filename: "отчёт.pdf")
  end

  def data_inline
    send_data("PNGDATA", type: "image/png", disposition: "inline", status: :created)
  end

  def data_no_disposition
    send_data("x", disposition: nil)
  end

  def file_default
    send_file(File.join(DIR, "notes.txt"))
  end

  def file_pdf
    send_file(File.join(DIR, "report.pdf"))
  end

  def file_unknown_ext
    send_file(File.join(DIR, "data.bin"))
  end

  def file_inline_status
    send_file(File.join(DIR, "notes.txt"),
              type: "text/plain; charset=utf-8", disposition: "inline", status: 404)
  end

  def file_url_based
    send_file(File.join(DIR, "notes.txt"), url_based_filename: true)
  end

  def file_missing
    send_file(File.join(DIR, "nope.txt"))
  end

  def file_utf8_name
    send_file(File.join(DIR, "страница.html"))
  end
end

def call(action)
  app = ActionDispatch::ShowExceptions.new(DataController.action(action), nil)
  env = Rack::MockRequest.env_for("/#{action}")
  status, headers, body = app.call(env)
  chunks = []
  body.each { |c| chunks << c }
  [status,
   headers["Content-Type"] || "",
   headers["Content-Disposition"] || "",
   headers["Content-Transfer-Encoding"] || "",
   headers["Content-Length"] || "",
   chunks.join].join("|")
rescue => e
  "raise:#{e.class.name}"
end

def call_bare(action)
  # без ShowExceptions — класс исключения, как в csrf-оракуле
  env = Rack::MockRequest.env_for("/#{action}")
  status, headers, body = DataController.action(action).call(env)
  chunks = []
  body.each { |c| chunks << c }
  [status,
   headers["Content-Type"] || "",
   headers["Content-Disposition"] || "",
   headers["Content-Transfer-Encoding"] || "",
   headers["Content-Length"] || "",
   chunks.join].join("|")
end

case_run("data_default") { call(:data_default) }
case_run("data_filename") { call(:data_filename) }
case_run("data_filename_utf8") { call(:data_filename_utf8) }
case_run("data_inline") { call(:data_inline) }
case_run("data_no_disposition") { call(:data_no_disposition) }
case_run("file_default") { call(:file_default) }
case_run("file_pdf") { call(:file_pdf) }
case_run("file_unknown_ext") { call(:file_unknown_ext) }
case_run("file_inline_status") { call(:file_inline_status) }
case_run("file_url_based") { call(:file_url_based) }
case_run("file_missing") { call_bare(:file_missing) }
case_run("file_utf8_name") { call(:file_utf8_name) }
