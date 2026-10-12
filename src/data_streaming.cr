# ActionController::DataStreaming — порт actionpack 8.1.4
# lib/action_controller/metal/data_streaming.rb + lib/action_dispatch/
# http/content_disposition.rb.
#
# Oracle: oracle/data_streaming_cases.rb →
# oracle/data_streaming_expected.yml (12 кейсов с настоящего actionpack
# 8.1.4), зеркало — railties.cr/spec/data_streaming_spec.cr.
#
# Семантика 1:1:
# - send_data: тело строкой, send_file: файл с диска (стрим);
# - Content-Type: явный type:, иначе вывод по расширению filename,
#   иначе application/octet-stream; БЕЗ charset (sending_file=true);
# - Content-Disposition: disposition ("attachment" дефолт, nil — без
#   заголовка); с filename — двойной формат как в геме:
#   `disp; filename="<ascii>"; filename*=UTF-8''<rfc5987>`; ascii-имя
#   без транслитерации в bare-геме даёт "?" на не-ASCII → %3F;
# - Content-Transfer-Encoding: binary;
# - send_file: отсутствующий файл → ActionController::MissingFile
#   (railties-лестница маппит в 404, как rescue_responses Rails);
# - status: число или символ (:created → 201).
#
# Задокументированные отклонения от гема:
# - Range-запросы для send_file (Rack::Files slice) — P2;
# - MIME-вывод — подмножество Rack::Mime (частые расширения);
#   незнакомое расширение → application/octet-stream, как в геме;
# - type: — String (Symbol-имена зарегистрированных Mime — P2);
# - Content-Length не ставится приложением (как в геме — стрим);
#   на проводе его добавляет HTTP::Server.

module ActionController
  class MissingFile < Exception
  end

  module DataStreaming
    DEFAULT_SEND_FILE_TYPE        = "application/octet-stream"
    DEFAULT_SEND_FILE_DISPOSITION = "attachment"

    # Подмножество Rack::Mime для вывода типа по расширению.
    MIME_BY_EXT = {
      "html" => "text/html", "htm" => "text/html",
      "txt"  => "text/plain", "css" => "text/css",
      "js"   => "text/javascript", "mjs" => "text/javascript",
      "json" => "application/json", "pdf" => "application/pdf",
      "png"  => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg",
      "gif"  => "image/gif", "svg" => "image/svg+xml", "webp" => "image/webp",
      "ico"  => "image/vnd.microsoft.icon", "xml" => "application/xml",
      "csv"  => "text/csv", "zip" => "application/zip",
      "gz"   => "application/gzip", "tgz" => "application/gzip",
      "mp4"  => "video/mp4", "webm" => "video/webm", "mp3" => "audio/mpeg",
      "wasm" => "application/wasm", "woff" => "font/woff",
      "woff2" => "font/woff2",
    } of String => String

    # send_data "pdf!", filename: "report.pdf", type: "application/pdf"
    def send_data(data : String, filename : String? = nil, type : String? = nil,
                  disposition : String? = DEFAULT_SEND_FILE_DISPOSITION,
                  status : Int32 | Symbol = 200,
                  content_type : String? = nil) : Nil
      ct = __data_streaming_headers(type, filename, disposition)
      ct = content_type if content_type
      @performed = true
      response.status_code = status_code(status)
      response.headers["Content-Type"] = ct
      __verify_same_origin_request
      response.print data
    end

    # send_file "/path/report.pdf", disposition: "inline", status: 404
    def send_file(path : String, filename : String? = nil, type : String? = nil,
                  disposition : String? = DEFAULT_SEND_FILE_DISPOSITION,
                  status : Int32 | Symbol = 200,
                  content_type : String? = nil,
                  url_based_filename : Bool = false) : Nil
      unless File.file?(path)
        raise MissingFile.new("Cannot read file #{path}")
      end
      filename = File.basename(path) unless filename || url_based_filename
      ct = __data_streaming_headers(type, filename, disposition)
      ct = content_type if content_type
      @performed = true
      response.status_code = status_code(status)
      response.headers["Content-Type"] = ct
      __verify_same_origin_request
      File.open(path) { |file| IO.copy(file, response) }
    end

    private def __data_streaming_headers(type : String?, filename : String?,
                                         disposition : String?) : String
      content_type = type || (filename.try { |f|
        MIME_BY_EXT[File.extname(f).downcase.delete(".")]?
      }) || DEFAULT_SEND_FILE_TYPE

      if disposition
        response.headers["Content-Disposition"] =
          ContentDisposition.format(disposition, filename)
      end
      response.headers["Content-Transfer-Encoding"] = "binary"
      content_type
    end

    # Порт ActionDispatch::Http::ContentDisposition:
    # "disp; filename=\"<ascii>\"; filename*=UTF-8''<rfc5987>".
    module ContentDisposition
      # [ A-Za-z0-9!#$+.^_`|~-] — TRADITIONAL_ESCAPED_CHAR
      def self.ascii_filename(filename : String) : String
        String.build do |io|
          filename.each_char do |char|
            if char.ord < 128 && allowed_traditional?(char)
              io << char
            elsif char.ord >= 128
              # bare-гем: I18n.transliterate без правил заменяет не-ASCII
              # на "?" — и он же уходит в percent-escape (%3F)
              io << "%3F"
            else
              escape_bytes(io, char.to_s)
            end
          end
        end
      end

      # [A-Za-z0-9!#$&+.^_`|~-] — RFC_5987_ESCAPED_CHAR (без пробела,
      # но с &)
      def self.utf8_filename(filename : String) : String
        String.build do |io|
          filename.each_char do |char|
            if char.ord < 128 && allowed_rfc5987?(char)
              io << char
            else
              escape_bytes(io, char.to_s)
            end
          end
        end
      end

      def self.format(disposition : String, filename : String?) : String
        if filename
          "#{disposition}; filename=\"#{ascii_filename(filename)}\"; " \
          "filename*=UTF-8''#{utf8_filename(filename)}"
        else
          disposition
        end
      end

      private def self.allowed_traditional?(char : Char) : Bool
        allowed_char?(char, with_space: true, with_amp: false)
      end

      private def self.allowed_rfc5987?(char : Char) : Bool
        allowed_char?(char, with_space: false, with_amp: true)
      end

      private def self.allowed_char?(char : Char, with_space : Bool, with_amp : Bool) : Bool
        return true if char.ascii_letter? || char.number?
        return true if with_space && char == ' '
        return true if with_amp && char == '&'
        "!#$+.^_`|~-".includes?(char)
      end

      private def self.escape_bytes(io : IO, string : String) : Nil
        string.each_byte do |byte|
          io << '%' << byte.to_s(16).upcase.rjust(2, '0')
        end
      end
    end
  end

  class Base
    include DataStreaming
  end
end
