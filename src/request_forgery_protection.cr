# ActionController::RequestForgeryProtection — порт actionpack 8.1.4
# lib/action_controller/metal/request_forgery_protection.rb (Iteration 12)
# + слой Rails 8.2 (header_only): verification-стратегии по Sec-Fetch-Site
# (rails/rails main, 8.2.0.alpha — Campfire использует
# `protect_from_forgery using: :header_only, with: :exception`).
#
# Oracle: oracle/csrf_expected.yml (28 кейсов, actionpack 8.1.4, снят через
# oracle/csrf_cases.rb), зеркало — railties.cr/spec/csrf_spec.cr.
# header_only-слой 8.1.4 не содержит — оракул таблицы истинности
# verified_via_header_only?/verified_with_legacy_token? — исходник
# rails/rails@main request_forgery_protection.rb (цитаты в комментариях),
# спек-зеркало — там же в csrf_spec.cr (describe "header_only").
#
# Семантика 1:1 с 8.1.4:
# - real-токен: 32 случайных байта в сессии (`_csrf_token`, urlsafe b64
#   без паддинга), кэш на запрос;
# - маскирование от BREACH: mask(32) ++ (mask XOR raw), urlsafe b64 без
#   паддинга; размаскированный принимается и как 64, и как 32 байта
#   (легаси-немаскированные токены);
# - глобальный токен = HMAC-SHA256(real, "!real_csrf_token") — его отдают
#   form_authenticity_token/csrf_meta_tags, валиден для любой формы;
# - per-form токен = HMAC-SHA256(real, "#{path}##{method.downcase}")
#   (per_form_csrf_tokens, по умолчанию false — как в bare-геме; Rails
#   включает через load_defaults 5.2);
# - проверка: GET/HEAD пропускаются; param `authenticity_token` ИЛИ хедер
#   `X-CSRF-Token`; fixed-length сравнение (Crypto::Subtle);
# - Origin-проверка (forgery_protection_origin_check, по умолчанию false):
#   Origin != base_url → 422; пустой Origin допускается, "null" — нет;
# - стратегии: :exception (InvalidAuthenticityToken → 422 через
#   railties-лестницу), :null_session (сессия пустая на время запроса,
#   клиентская сессия НЕ трогается), :reset_session (сессия сбрасывается
#   насовсем); :null_session — дефолт, как в геме;
# - after-проверка JS-ответов: GET помечается, и если ответ
#   text|application/javascript пришёл не-XHR запросу —
#   InvalidCrossOriginRequest → 422 (защита от кросс-доменного
#   <script src=...>).
#
# Задокументированные отклонения от гема:
# - конфиг глобальный (ActionController::RequestForgeryProtection.
#   allow_forgery_protection= и т.п.), а не per-class мутаторы — как
#   config.action_controller.* в приложении; per-class `self.x = `
#   встречаются только в тестах гема;
# - `with:` принимает Symbol (null_session/reset_session/exception),
#   кастомные strategy-классы и `store: :cookie` — P2;
# - null_session подменяет сессию в памяти контроллера (чтения — пусто,
#   записи отбрасываются), cookie клиенту не пишется — семантика
#   «сессия не сброшена, запрос обслужен с пустой» совпадает с оракулом;
# - form_options передаются именованными аргументами
#   form_authenticity_token(action:, method:), не хешем;
# - request.ssl? (8.2, plain-HTTP-фоллбэк header_only) определяется по
#   X-Forwarded-Proto терминирующего TLS-прокси + глобальный
#   force_secure_protocol; прямого TLS-листенера у стека нет;
# - QUERY exempt без _method=query-туннелирования (Rack::MethodOverride
#   QUERY не поддерживает).

require "openssl/hmac"

module ActionController
  # 8.2: InvalidAuthenticityToken — депрекейтед-алиас
  # InvalidCrossOriginRequest (подкласс: rescue по родителю ловит оба).
  class InvalidCrossOriginRequest < Exception
  end

  class InvalidAuthenticityToken < InvalidCrossOriginRequest
  end

  module RequestForgeryProtection
    AUTHENTICITY_TOKEN_LENGTH = 32
    GLOBAL_CSRF_TOKEN_IDENTIFIER = "!real_csrf_token"
    CSRF_PARAM_NAME = "authenticity_token"

    # Глобальный конфиг (аналог config.action_controller.*). Логирование
    # провала — на railties-слое (422 в лестнице ShowExceptions), у шарда
    # нет своего логгера.
    class_property allow_forgery_protection : Bool = true
    class_property per_form_csrf_tokens : Bool = false
    class_property forgery_protection_origin_check : Bool = false

    # Rails 8.2: :header_only | :header_or_legacy_token (дефолт гема —
    # гибрид; приложение Campfire ставит :header_only через `using:`).
    class_property forgery_protection_verification_strategy : Symbol = :header_or_legacy_token
    # Разрешённые кросс-сайт источники (Origin-строки) — OAuth/SSO-колбэки.
    class_property forgery_protection_trusted_origins : Array(String) = [] of String
    # Аналог ActionDispatch::Http::URL.secure_protocol: запрос без
    # Sec-Fetch-Site заголовка (header_only) разрешён только по plain HTTP.
    class_property force_secure_protocol : Bool = false

    # protect_from_forgery with: :exception, using: :header_only,
    #                      only: [...], except: [...], if:, unless:
    # `with:` — Crystal-ключевое слово, читается из **opts (как в
    # rate_limit). Дефолт — :null_session, как в геме.
    macro protect_from_forgery(only = nil, except = nil, using = nil, **opts)
      {% strategy = opts["with"] || :null_session %}
      {% unless [:null_session, :reset_session, :exception].includes?(strategy) %}
        {% raise "protect_from_forgery: unsupported with: #{strategy} (use :null_session, :reset_session or :exception)" %}
      {% end %}
      {% if using %}
        {% unless [:header_only, :header_or_legacy_token].includes?(using) %}
          {% raise "protect_from_forgery: unsupported using: #{using} (use :header_only or :header_or_legacy_token)" %}
        {% end %}
      {% end %}

      # Стратегия обработки непроверенного запроса — на класс.
      def __forgery_strategy : Symbol
        {{ strategy }}
      end

      # Verification-стратегия: литерал из `using:` либо глобальный конфиг
      # (гем: options[:using] || forgery_protection_verification_strategy).
      def __forgery_verification_strategy : Symbol
        {% if using %}
          {{ using }}
        {% else %}
          ::ActionController::RequestForgeryProtection.forgery_protection_verification_strategy
        {% end %}
      end

      # Флаг для форм/csrf_meta_tags: контроллер под защитой.
      def __protect_against_forgery? : Bool
        ::ActionController::RequestForgeryProtection.allow_forgery_protection
      end

      # Скрытое поле токена в формах (виден формам через render-контекст).
      protected def __csrf_token_field(action : String, method : String) : String
        return "" if method == "get"
        token = form_authenticity_token(action: action, method: method)
        %(<input type="hidden" name="#{CSRF_PARAM_NAME}" value="#{token}" autocomplete="off" />)
      end

      # Токен для csrf_meta_tags (глобальный, XHR-флоу).
      protected def __csrf_meta_token : String?
        form_authenticity_token
      end

      # before_action: проверка запроса (токен и/или Sec-Fetch-Site).
      def __verify_authenticity_token : Nil
        @__csrf_verification_ran = true
        __mark_for_same_origin_verification
        unless __verified_request?
          __handle_unverified_request
        end
      end

      # after-render: JS-ответ не-XHR запросу после GET — кросс-доменное
      # встраивание <script>. Вызывается перед коммитом тела ответа.
      # 8.2: туда же вшит append_sec_fetch_site_to_vary_header — после-
      # экшн protect_from_forgery (skip_forgery_protection убирает оба).
      def __verify_same_origin_request : Nil
        if @__csrf_verification_ran
          __append_sec_fetch_site_to_vary_header
        end
        return unless @__csrf_marked
        ct = response.headers["Content-Type"]?
        return unless ct && (ct.starts_with?("text/javascript") || ct.starts_with?("application/javascript"))
        return if request.headers["X-Requested-With"]? == "XMLHttpRequest"
        raise ::ActionController::InvalidCrossOriginRequest.new(
          "Security warning: an embedded <script> tag on another site requested protected JavaScript.")
      end

      {% if only && !only.is_a?(ArrayLiteral) %}{% only = [only] %}{% end %}
      {% if except && !except.is_a?(ArrayLiteral) %}{% except = [except] %}{% end %}
      {% ActionController::FILTERS << { @type, :"__verify_authenticity_token", {only: only, except: except, if: opts[:if], unless: opts[:unless]} } %}
    end

    # skip_forgery_protection — обёртка skip_before_action
    # :verify_authenticity_token, как в геме.
    macro skip_forgery_protection
      skip_before_action :__verify_authenticity_token
    end

    # --- token machinery (доступны контроллеру и вьюхам) ----------------

    # Глобальный токен (глобальный HMAC) или per-form для action/method.
    def form_authenticity_token(action : String? = nil, method : String? = nil) : String
      raw =
        if RequestForgeryProtection.per_form_csrf_tokens && action && method
          __csrf_token_hmac("#{__normalize_action_path(action)}##{method.downcase}")
        else
          __csrf_token_hmac(GLOBAL_CSRF_TOKEN_IDENTIFIER)
        end
      __mask_csrf_token(raw)
    end

    # --- internals -------------------------------------------------------

    @__csrf_real_token : Bytes?
    @__csrf_marked : Bool = false
    # protect_from_forgery применился к экшену (не skip и не unless) —
    # флаг для Vary-послеэкшена 8.2.
    @__csrf_verification_ran : Bool = false

    def __mark_for_same_origin_verification : Nil
      @__csrf_marked = request.method == "GET"
    end

    private def __verified_request? : Bool
      method = request.method
      # 8.2: QUERY-запросы exempt как GET/HEAD (HTML-форма QUERY не
      # шлёт; туннелирование через _method=query не поддерживается —
      # документированное отклонение).
      return true if method == "GET" || method == "HEAD" || method == "QUERY"
      return true unless __protect_against_forgery?
      __valid_request_origin? && __verified_request_for_forgery_protection?
    end

    # 8.2 verified_request_for_forgery_protection?: ветвление по
    # forgery_protection_verification_strategy.
    private def __verified_request_for_forgery_protection? : Bool
      if __forgery_verification_strategy == :header_only
        __verified_via_header_only?
      else
        __verified_with_legacy_token?
      end
    end

    # 8.2 sec_fetch_site_value: нормализованный (downcase, presence) хедер.
    private def __sec_fetch_site : String?
      request.headers["Sec-Fetch-Site"]?.try(&.downcase.presence)
    end

    # 8.2 verified_via_header_only?: same-origin/same-site — ок;
    # cross-site — только доверенный Origin; заголовка нет — только
    # plain HTTP; "none" и мусор — отказ.
    private def __verified_via_header_only? : Bool
      case __sec_fetch_site
      when "same-origin", "same-site"
        true
      when "cross-site"
        __origin_trusted?
      when nil
        !__ssl_request?
      else
        false
      end
    end

    # 8.2 verified_with_legacy_token?: same-site — ок, cross-site —
    # доверенный Origin, "none"/нет заголовка — фоллбэк на токен.
    private def __verified_with_legacy_token? : Bool
      case __sec_fetch_site
      when "same-origin", "same-site"
        true
      when "cross-site"
        __origin_trusted?
      else
        __any_authenticity_token_valid?
      end
    end

    # 8.2 origin_trusted?: непустой Origin из trusted_origins.
    private def __origin_trusted? : Bool
      origin = request.headers["Origin"]?
      !origin.nil? && !origin.empty? &&
        RequestForgeryProtection.forgery_protection_trusted_origins.includes?(origin)
    end

    # request.ssl? — терминированный TLS-прокси помечает X-Forwarded-Proto.
    private def __ssl_request? : Bool
      RequestForgeryProtection.force_secure_protocol ||
        (request.headers["X-Forwarded-Proto"]? || "http") == "https"
    end

    # 8.2 append_sec_fetch_site_to_vary_header: ответ зависит от
    # Sec-Fetch-Site — кеши обязаны варьировать.
    private def __append_sec_fetch_site_to_vary_header : Nil
      vary = response.headers["Vary"]?.to_s.split(",").map(&.strip).reject(&.empty?)
      vary << "Sec-Fetch-Site" unless vary.includes?("Sec-Fetch-Site")
      response.headers["Vary"] = vary.join(", ")
    end

    private def __any_authenticity_token_valid? : Bool
      param_token = params[CSRF_PARAM_NAME]?.try(&.to_s)
      header_token = request.headers["X-CSRF-Token"]?
      __valid_authenticity_token?(param_token) || __valid_authenticity_token?(header_token)
    end

    # Маскированный (64 байта после декода) или немаскированный (32)
    # токен: глобальный HMAC | real | per-form — порядок как в 8.1.4.
    def __valid_authenticity_token?(encoded : String?) : Bool
      return false if encoded.nil? || encoded.empty?
      masked = __csrf_b64_decode(encoded)
      return false unless masked

      case masked.size
      when AUTHENTICITY_TOKEN_LENGTH
        __compare_with_real_token(masked)
      when AUTHENTICITY_TOKEN_LENGTH * 2
        one_time_pad = masked[0, AUTHENTICITY_TOKEN_LENGTH]
        encrypted = masked[AUTHENTICITY_TOKEN_LENGTH, AUTHENTICITY_TOKEN_LENGTH]
        token = __xor_bytes(one_time_pad, encrypted)
        __compare_with_global_token(token) ||
          __compare_with_real_token(token) ||
          __valid_per_form_csrf_token?(token)
      else
        false
      end
    end

    # 8.2 unverified_request_warning_message: причина отказа.
    private def __unverified_request_warning_message : String
      if !__valid_request_origin?
        "HTTP Origin header (#{request.headers["Origin"]?}) didn't match request base URL"
      elsif __sec_fetch_site == "cross-site"
        "Sec-Fetch-Site header (cross-site) indicates a cross-site request"
      elsif __forgery_verification_strategy == :header_only
        "Sec-Fetch-Site header is missing or invalid (#{__sec_fetch_site.inspect})"
      else
        "Can't verify CSRF token authenticity."
      end
    end

    private def __handle_unverified_request : Nil
      case __forgery_strategy
      when :exception
        # 8.2: InvalidAuthenticityToken депрекейтед в пользу
        # InvalidCrossOriginRequest (алиас). header_only отказывает по
        # Sec-Fetch-Site — поднимаем новый класс; токен-провалы
        # (header_or_legacy_token) — подкласс ради совместимости с
        # зеркалом 8.1.4.
        if __forgery_verification_strategy == :header_only
          raise ::ActionController::InvalidCrossOriginRequest.new(__unverified_request_warning_message)
        else
          raise ::ActionController::InvalidAuthenticityToken.new(__unverified_request_warning_message)
        end
      when :reset_session
        session.reset
      else # :null_session
        session.nullify!
      end
    end

    # Origin-проверка: пустой Origin допускается (не все UA его шлют),
    # "null" и чужой домен — нет. base_url: схема (X-Forwarded-Proto для
    # прокси) + Host-хедер, как request.base_url.
    private def __valid_request_origin? : Bool
      return true unless RequestForgeryProtection.forgery_protection_origin_check
      origin = request.headers["Origin"]?
      return true if origin.nil? || origin.empty?
      scheme = request.headers["X-Forwarded-Proto"]? || "http"
      host = request.headers["Host"]?
      return true if host.nil?
      origin == "#{scheme}://#{host}"
    end

    private def __valid_per_form_csrf_token?(token : Bytes) : Bool
      return false unless RequestForgeryProtection.per_form_csrf_tokens
      correct = __csrf_token_hmac("#{request.path.chomp('/')}##{request.method.downcase}")
      __secure_compare(token, correct)
    end

    private def __compare_with_real_token(token : Bytes) : Bool
      __secure_compare(token, __real_csrf_token)
    end

    private def __compare_with_global_token(token : Bytes) : Bool
      __secure_compare(token, __csrf_token_hmac(GLOBAL_CSRF_TOKEN_IDENTIFIER))
    end

    # 32 случайных байта в сессии (urlsafe b64 без паддинга), кэш на
    # запрос — аналог env[CSRF_TOKEN] в геме.
    private def __real_csrf_token : Bytes
      @__csrf_real_token ||= begin
        stored = session["_csrf_token"]?
        token =
          if stored && (decoded = __csrf_b64_decode(stored)) && decoded.size == AUTHENTICITY_TOKEN_LENGTH
            decoded
          else
            fresh = Random::Secure.random_bytes(AUTHENTICITY_TOKEN_LENGTH)
            session["_csrf_token"] = Base64.urlsafe_encode(fresh, padding: false)
            fresh
          end
        token
      end
    end

    private def __csrf_token_hmac(identifier : String) : Bytes
      OpenSSL::HMAC.digest(:sha256, __real_csrf_token, identifier)
    end

    private def __mask_csrf_token(raw : Bytes) : String
      one_time_pad = Random::Secure.random_bytes(AUTHENTICITY_TOKEN_LENGTH)
      Base64.urlsafe_encode(one_time_pad + __xor_bytes(one_time_pad, raw), padding: false)
    end

    private def __xor_bytes(s1 : Bytes, s2 : Bytes) : Bytes
      out = Bytes.new(s1.size)
      s1.size.times { |i| out[i] = s1[i] ^ s2[i] }
      out
    end

    # urlsafe b64 с любым паддингом; nil на мусоре (не исключение).
    private def __csrf_b64_decode(encoded : String) : Bytes?
      s = encoded.gsub('+', '-').gsub('/', '_')
      while s.ends_with?('=')
        s = s.rchop('=')
      end
      case s.size % 4
      when 2 then s += "=="
      when 3 then s += "="
      end
      Base64.decode(s)
    rescue
      nil
    end

    # fixed_length_secure_compare: разная длина — false, иначе
    # constant-time (Crypto::Subtle).
    private def __secure_compare(a : Bytes, b : Bytes) : Bool
      return false unless a.size == b.size
      Crypto::Subtle.constant_time_compare(a, b)
    end

    private def __normalize_action_path(action : String) : String
      if action.starts_with?('/')
        action.chomp('/')
      else
        "#{request.path.chomp('/')}/#{action}".gsub("/./", "/")
      end
    end
  end

  class Base
    include RequestForgeryProtection
  end
end
