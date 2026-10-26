# ActionController::ConditionalGet — порт actionpack 8.1.4
# (action_controller/metal/conditional_get.rb + action_dispatch/http/cache.rb).
#
# Oracle: oracle/conditional_get_cases.rb → oracle/conditional_get_expected.yml
# (20 кейсов, rails 8.1.4 throwaway-app: weak/strong ETag формат, 304 по
# If-None-Match / If-Modified-Since, приоритет ETag, Cache-Control,
# stale?). Зеркало: spec/conditional_get_spec.cr.
#
# Ключевые факты оракула:
#   * weak ETag: W/"<sha256[0,32]>" (ActiveSupport::Digest.hexdigest —
#     SHA256, усечённый до 32 hex; expand_cache_key(["v1"]) = "v1");
#     strong ETag — без W/;
#   * fresh? (non-strict, дефолт): оба присутствующих условия AND;
#     If-None-Match — список через ",", точное строковое совпадение
#     (включая W/) или "*"; If-Modified-Since >= Last-Modified → fresh;
#   * Cache-Control: public: true → "public"; иначе при выставленном
#     ETag — "max-age=0, private, must-revalidate" (в Rails это ставит
#     Rack::ETag — здесь же, в fresh_when, documented deviation);
#   * fresh → head 304 (пустое тело), performed (render после
#     fresh_when при fresh-запросе — DoubleRenderError, как в Rails);
#   * Last-Modified: httpdate "Thu, 01 Jan 2026 12:00:00 GMT".
#
# Отклонения от гема: record-валидаторы (fresh_when @article) и
# template-digest в ETag не портированы (etag — строка); expires_in /
# http_cache_forever / no_store — не из этого оракула.

require "digest/sha256"

module ActionController
  module ConditionalGet
    # ActiveSupport::Digest.hexdigest: SHA256, усечённый до 32 hex.
    private def conditional_etag_hexdigest(validators : Array(String)) : String
      Digest::SHA256.hexdigest(validators.join("/"))[0, 32]
    end

    # W/"..." (weak) или "..." (strong).
    private def conditional_etag_header(validators : Array(String), weak : Bool) : String
      etag = %("#{conditional_etag_hexdigest(validators)}")
      weak ? "W/#{etag}" : etag
    end

    # fresh_when(etag: "v1") — слабый валидатор; strong_etag: — сильный.
    # Возвращает true, если ответ fresh (выставлен 304), иначе false.
    def fresh_when(*, etag : String? = nil, weak_etag : String? = nil,
                   strong_etag : String? = nil, last_modified : Time? = nil,
                   public : Bool = false) : Bool
      weak = weak_etag || etag
      if strong_etag
        response.headers["ETag"] = conditional_etag_header([strong_etag], weak: false)
      elsif weak
        response.headers["ETag"] = conditional_etag_header([weak], weak: true)
      end
      response.headers["Last-Modified"] = httpdate(last_modified) if last_modified
      if public
        response.headers["Cache-Control"] = "public"
      elsif response.headers["ETag"]? && !response.headers["Cache-Control"]?
        # Rack::ETag default (deviation: inlined here)
        response.headers["Cache-Control"] = "max-age=0, private, must-revalidate"
      end

      if request_fresh?
        head :not_modified
        true
      else
        false
      end
    end

    # stale? — инверсия fresh_when: true → ответ устарел, рендерить.
    def stale?(**opts) : Bool
      !fresh_when(**opts)
    end

    # expires_in 1.year, public: true — Rails Cache-Control builder
    # (actionpack's ActionController::Instrumentation#expires_in over
    # ActionDispatch::Response::CacheControl): directives in order
    # public/private → max-age → must-revalidate; a zero/negative span
    # drops max-age. `1.year` (ActiveSupport::Duration) and raw
    # seconds/Time::Span all convert via #to_i. `private:` rides in
    # **opts (Crystal keyword).
    def expires_in(seconds, *, public : Bool = false, must_revalidate : Bool = false,
                   **opts) : Nil
      total = seconds.is_a?(Time::Span) ? seconds.total_seconds.to_i : seconds.to_i
      directives = [] of String
      directives << "public" if public
      directives << "private" if opts["private"]? == true
      directives << "max-age=#{total}" if total > 0
      directives << "must-revalidate" if must_revalidate
      response.headers["Cache-Control"] = directives.join(", ") unless directives.empty?
    end

    # request.fresh? — strict_freshness режим, дефолт Rails 8.1
    # (load_defaults 8.1; подтверждён оракулом fw_both_inm_wins_304):
    # If-None-Match присутствует → только сравнение ETag, If-Modified-Since
    # игнорируется (RFC 7232 §6, приоритет валидатора); иначе
    # If-Modified-Since >= Last-Modified; нет условных заголовков — false.
    private def request_fresh? : Bool
      if (inm = request.headers["If-None-Match"]?)
        etag_matches?(inm, response.headers["ETag"]?)
      elsif request.headers["If-Modified-Since"]?
        if (since = if_modified_since) && (modified_at = response_last_modified)
          since >= modified_at
        else
          false
        end
      else
        false
      end
    end

    # If-None-Match: список через ",", точное совпадение или "*".
    private def etag_matches?(if_none_match : String, etag : String?) : Bool
      validators = if_none_match.split(",").map(&.strip)
      return true if validators.includes?("*")
      !!(etag && validators.includes?(etag))
    end

    private def if_modified_since : Time?
      return nil unless raw = request.headers["If-Modified-Since"]?
      parse_httpdate(raw)
    end

    private def response_last_modified : Time?
      return nil unless raw = response.headers["Last-Modified"]?
      parse_httpdate(raw)
    end

    # httpdate: "Thu, 01 Jan 2026 12:00:00 GMT" (GMT-литерал срезаем —
    # %Z в Crystal не парсит имена зон; битые даты — nil, как
    # `Time.httpdate rescue nil` гема).
    private def parse_httpdate(raw : String) : Time?
      Time.parse(raw.gsub(" GMT", ""), "%a, %d %b %Y %H:%M:%S",
        Time::Location::UTC)
    rescue ex : ArgumentError
      nil
    end

    private def httpdate(time : Time) : String
      time.to_utc.to_s("%a, %d %b %Y %H:%M:%S GMT")
    end
  end
end
