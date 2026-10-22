# Cookies / session / flash (cookie store) — порт ActionDispatch::Cookies
# (actionpack 8.1.4 lib/action_dispatch/middleware/cookies.rb).
#
# Wire-форматы побайтово совместимы с гемом (оракул
# oracle/cookies_cases.rb → oracle/cookies_expected.yml, реверс —
# oracle/verify_cookies.rb):
# - `cookies.signed`   — MessageVerifier(key = KeyGenerator(secret,
#   iterations: 1000).generate_key("signed cookie"), digest: SHA1,
#   legacy-конверт {"_rails":{"message":b64(json),"exp":..,"pur":..}});
# - `cookies.encrypted`— MessageEncryptor aes-256-gcm с ключом
#   generate_key("authenticated encrypted cookie", 32), тот же конверт
#   внутри шифротекста;
# - purpose изоляция "cookie.#{name}", чтение с fallback-ом без purpose
#   (как AbstractCookieJar#[] в геме);
# - `cookies.permanent` (+ цепочки .permanent.signed) — cookie-level
#   expires = 20 лет; message-level exp при этом НЕ ставится (commit
#   подписанного значения идёт раньше, чем permanent выставит expires).
#
# Отклонения от гема: Set-Cookie пишется прямо в response.headers (нет
# отложенного jar.commit); secure-cookie поверх plain HTTP дропается по
# X-Forwarded-Proto (HTTP::Server не знает о TLS-терминации); session/
# flash без секретa пишутся неподписанным Base64-JSON (legacy-режим порта,
# чтение обоих форматов); SameSite по умолчанию не инжектится
# (cookies_same_site_protection = nil — территория railties).
#
# Семантика flash (как в Rails): `flash[k] = v` виден в ТЕКУЩЕМ запросе
# (рендер без редиректа) и переносится на следующий, если его не прочитали;
# чтение помечает ключ использованным (Rails: sweep по @used). `flash.now` —
# только текущий запрос.

require "base64"
require "json"
require "uri"
require "active_support_cr"

module ActionController
  # Secret key base для signed/encrypted джарбов. Railties выставляет на
  # буте (фаза Credentials); fallback — ENV["SECRET_KEY_BASE"]. Без секрета
  # обращение к cookies.signed / cookies.encrypted — RuntimeError (как в
  # Rails без secret_key_base), session/flash деградируют до неподписанного
  # legacy-режима.
  @@cookies_secret_key_base : String?
  @@key_generator : ActiveSupport::CachingKeyGenerator?

  def self.cookies_secret_key_base=(secret : String?) : Nil
    @@cookies_secret_key_base = secret
    @@key_generator = nil
  end

  def self.cookies_secret_key_base : String?
    @@cookies_secret_key_base || ENV["SECRET_KEY_BASE"]?
  end

  def self.cookie_key_generator : ActiveSupport::CachingKeyGenerator
    secret = cookies_secret_key_base
    raise RuntimeError.new(
      "ActionController::Cookies: secret_key_base is not configured — " \
      "set ActionController.cookies_secret_key_base or SECRET_KEY_BASE " \
      "to use signed/encrypted cookies") unless secret
    # iterations 1000 — как в finisher'е приложения Rails
    @@key_generator ||= ActiveSupport::CachingKeyGenerator.new(
      ActiveSupport::KeyGenerator.new(secret, iterations: 1000))
  end

  # Атрибуты Set-Cookie для одной cookie (value — уже wire-строка джарба).
  class CookieOptions
    attr_accessor value : String
    attr_accessor expires : Time?
    attr_accessor path : String = "/"
    attr_accessor domain : String?
    attr_accessor secure : Bool = false
    attr_accessor httponly : Bool = false
    attr_accessor same_site : Symbol?

    def initialize(@value : String)
    end
  end

  # Значение, которое можно положить в signed/encrypted джарб
  # (JSON-сериализуемое).
  alias CookiePayload = String | Int32 | Int64 | Bool |
                        Array(String | Symbol) |
                        Hash(String, ActiveSupport::MessageVerifier::MetadataScalar)

  class Cookies
    MAX_COOKIE_SIZE = 4096

    @signed_jar : SignedCookieJar?
    @encrypted_jar : EncryptedCookieJar?
    @permanent_jar : PermanentCookieJar?

    def initialize(@context : HTTP::Server::Context)
      @jar = {} of String => String
      request_cookies.each do |k, v|
        @jar[k] = v
      end
    end

    def [](name : String) : String?
      @jar[name]?
    end

    def []?(name : String) : String?
      @jar[name]?
    end

    def []=(name : String, value : String) : Cookies
      set(name, value)
      self
    end

    # Устанавливает cookie с опциями (Rails-семантика cookies[]= c хешем
    # опций): expires/path/domain/secure/httponly/same_site.
    def set(name : String, value : String, expires : Time? = nil,
            path : String = "/", domain : String? = nil, secure : Bool = false,
            httponly : Bool = false, same_site : Symbol? = nil) : Nil
      options = CookieOptions.new(value)
      options.expires = expires
      options.path = path
      options.domain = domain
      options.secure = secure
      options.httponly = httponly
      options.same_site = same_site
      __set(name, options)
    end

    # Удаляет cookie у клиента (значение "" + expires в прошлом).
    def delete(name : String, path : String = "/",
               domain : String? = nil) : Nil
      return unless @jar.has_key?(name)
      @jar.delete(name)
      options = CookieOptions.new("")
      options.path = path
      options.domain = domain
      __write_delete(name, options)
    end

    def has_key?(name : String) : Bool
      @jar.has_key?(name)
    end

    def signed : SignedCookieJar
      @signed_jar ||= SignedCookieJar.new(self)
    end

    def encrypted : EncryptedCookieJar
      @encrypted_jar ||= EncryptedCookieJar.new(self)
    end

    def permanent : PermanentCookieJar
      @permanent_jar ||= PermanentCookieJar.new(self)
    end

    # --- внутреннее -----------------------------------------------------

    # Финальная точка цепочки джарбов: кладёт wire-значение в jar и
    # рендерит Set-Cookie.
    protected def __set(name : String, options : CookieOptions) : Nil
      @jar[name] = options.value
      return if options.secure && !request_https?
      # Rails (ActionDispatch::Cookies): запрос по TLS автоматически
      # получает Secure на cookie — 20-летний session-токен не должен
      # уходить по http после логина через https.
      options.secure = true if request_https?
      @context.response.headers.add("Set-Cookie", __render(name, options))
    end

    protected def __write_delete(name : String, options : CookieOptions) : Nil
      # append, not overwrite: several cookies (session + flash) may be
      # deleted on the same response
      @context.response.headers.add("Set-Cookie", __render_delete(name, options))
    end

    # Порядок атрибутов — как Rack::Utils.set_cookie_header:
    # value; domain; path; max-age; expires; httponly; secure; samesite.
    private def __render(name : String, options : CookieOptions) : String
      String.build do |line|
        line << URI.encode_www_form(name) << "=" << URI.encode_www_form(options.value)
        if domain = options.domain
          line << "; domain=" << domain
        end
        line << "; path=" << options.path
        if expires = options.expires
          line << "; expires=" << expires.to_utc.to_s("%a, %d %b %Y %H:%M:%S GMT")
        end
        line << "; httponly" if options.httponly
        line << "; secure" if options.secure
        if same_site = options.same_site
          line << "; samesite=" << same_site
        end
      end
    end

    private def __render_delete(name : String, options : CookieOptions) : String
      String.build do |line|
        line << URI.encode_www_form(name) << "="
        if domain = options.domain
          line << "; domain=" << domain
        end
        line << "; path=" << options.path
        line << "; max-age=0"
        line << "; expires=Thu, 01 Jan 1970 00:00:00 GMT"
      end
    end

    private def request_https? : Bool
      @context.request.headers["X-Forwarded-Proto"]?.try(&.includes?("https")) || false
    end

    private def request_cookies : Hash(String, String)
      jar = {} of String => String
      header = @context.request.headers["Cookie"]?
      return jar unless header
      header.split(';').each do |part|
        # flag-cookie / пустой элемент: без '=' значение пустое (как Rack —
        # деструктуризация в Ruby подставляет nil, не IndexError).
        key, eq, value = part.partition('=')
        raw = eq.empty? ? "" : value.strip
        # write() URL-encodes values (base64 session payloads contain
        # +/=); decode on read so the round trip is stable.
        decoded = begin
          URI.decode_www_form(raw)
        rescue
          raw
        end
        jar[key.strip] = decoded
      end
      jar
    end
  end

  # Базовый класс под-jar'ов (AbstractCookieJar + ChainedCookieJars гема):
  # чтение идёт из base-jar с parse-трансформацией и fallback-ом без
  # purpose, запись — commit + передача опций родителю.
  abstract class AbstractCookieJar
    def initialize(@parent : Cookies | AbstractCookieJar)
    end

    attr_reader :parent

    def [](name : String) : JSON::Any | String | Nil
      if (data = base[name]?)
        result = parse(name, data, "cookie.#{name}")
        result.nil? ? parse(name, data, nil) : result
      end
    end

    def []?(name : String) : JSON::Any | String | Nil
      self[name]
    end

    def []=(name : String, value) : Nil
      set(name, value)
    end

    # Цепочки джарбов: cookies.permanent.signed / cookies.signed.permanent...
    def signed : SignedCookieJar
      SignedCookieJar.new(self)
    end

    def encrypted : EncryptedCookieJar
      EncryptedCookieJar.new(self)
    end

    def permanent : PermanentCookieJar
      PermanentCookieJar.new(self)
    end

    protected def base : Cookies
      parent = @parent
      parent.is_a?(Cookies) ? parent : parent.base
    end

    protected def __set(name : String, options : CookieOptions) : Nil
      commit(name, options)
      @parent.__set(name, options)
    end

    protected def commit(name : String, options : CookieOptions) : Nil
    end

    # SerializedCookieJars#parse гема: значение — JSON.
    protected def parse(name : String, data : String,
                        purpose : String?) : JSON::Any | String | Nil
      JSON.parse(data)
    rescue JSON::ParseException
      nil
    end

    protected def check_for_overflow!(name : String, options : CookieOptions) : Nil
      if name.bytesize + options.value.bytesize > Cookies::MAX_COOKIE_SIZE
        raise CookieOverflow.new("#{name} cookie overflowed with size " \
          "#{name.bytesize + options.value.bytesize} bytes")
      end
    end

    private def apply_options(options : CookieOptions, expires : Time?,
                              path : String, domain : String?, secure : Bool,
                              httponly : Bool, same_site : Symbol?) : Nil
      options.expires = expires
      options.path = path
      options.domain = domain
      options.secure = secure
      options.httponly = httponly
      options.same_site = same_site
    end
  end

  class CookieOverflow < Exception
  end

  # cookies.signed — подписанные значения (см. шапку файла).
  class SignedCookieJar < AbstractCookieJar
    def initialize(parent)
      super
      key = ActionController.cookie_key_generator.generate_key("signed cookie")
      @verifier = ActiveSupport::MessageVerifier.new(key, digest: :sha1,
        force_legacy_metadata_serializer: true)
    end

    def set(name : String, value : CookiePayload, expires : Time? = nil,
            path : String = "/", domain : String? = nil, secure : Bool = false,
            httponly : Bool = false, same_site : Symbol? = nil) : Nil
      options = CookieOptions.new("")
      apply_options(options, expires, path, domain, secure, httponly, same_site)
      options.value = @verifier.generate(value,
        purpose: "cookie.#{name}", expires_at: options.expires)
      check_for_overflow!(name, options)
      __set(name, options)
    end

    protected def parse(name : String, data : String,
                        purpose : String?) : JSON::Any | String | Nil
      @verifier.verified_any(data, purpose: purpose)
    end
  end

  # cookies.encrypted — зашифрованные значения (aes-256-gcm).
  class EncryptedCookieJar < AbstractCookieJar
    def initialize(parent)
      super
      key = ActionController.cookie_key_generator
        .generate_key("authenticated encrypted cookie", 32)
      @encryptor = ActiveSupport::MessageEncryptor.new(key,
        force_legacy_metadata_serializer: true)
    end

    def set(name : String, value : CookiePayload, expires : Time? = nil,
            path : String = "/", domain : String? = nil, secure : Bool = false,
            httponly : Bool = false, same_site : Symbol? = nil) : Nil
      options = CookieOptions.new("")
      apply_options(options, expires, path, domain, secure, httponly, same_site)
      options.value = @encryptor.encrypt_and_sign(value,
        purpose: "cookie.#{name}", expires_at: options.expires)
      check_for_overflow!(name, options)
      __set(name, options)
    end

    protected def parse(name : String, data : String,
                        purpose : String?) : JSON::Any | String | Nil
      @encryptor.decrypt_and_verify(data, purpose: purpose)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      nil
    end
  end

  # cookies.permanent — expires = 20 лет (cookie-level; message-level exp
  # не затрагивает — см. шапку файла).
  class PermanentCookieJar < AbstractCookieJar
    def set(name : String, value : String, expires : Time? = nil,
            path : String = "/", domain : String? = nil, secure : Bool = false,
            httponly : Bool = false, same_site : Symbol? = nil) : Nil
      options = CookieOptions.new(value)
      apply_options(options, expires, path, domain, secure, httponly, same_site)
      __set(name, options)
    end

    protected def __set(name : String, options : CookieOptions) : Nil
      options.expires = Time.utc + 20.years
      @parent.__set(name, options)
    end
  end

  class Session
    KEY = "crails_session"

    @data : Hash(String, String)
    @nullified : Bool = false

    def initialize(@cookies : Cookies)
      @data = {} of String => String
      if (raw = @cookies[KEY]?)
        # чтение: подписанная cookie, при провале — legacy Base64-JSON
        # (переходный режим порта; сессия без секрета пишется неподписанной)
        @data = read_signed(raw) || decode_legacy(raw)
      end
    end

    def [](key : String | Symbol) : String?
      @data[key.to_s]?
    end

    def []?(key : String | Symbol) : String?
      @data[key.to_s]?
    end

    def []=(key : String | Symbol, value : String) : Nil
      return if @nullified
      @data[key.to_s] = value
      persist
    end

    def delete(key : String | Symbol) : Nil
      @data.delete(key.to_s)
      persist
    end

    def reset : Nil
      @data.clear
      persist
    end

    # NullSession-семантика CSRF-слоя (protect_from_forgery with:
    # :null_session): на остаток запроса сессия читается пустой, записи
    # отбрасываются, клиентская cookie НЕ перезаписывается — следующему
    # запросу достанется исходная сессия (Rails: NullSessionHash +
    # session_options skip: true).
    def nullify! : Nil
      @data.clear
      @nullified = true
    end

    private def signed_session? : Bool
      !!ActionController.cookies_secret_key_base
    end

    private def read_signed(raw : String) : Hash(String, String)?
      return nil unless signed_session?
      return nil unless (v = @cookies.signed[KEY]) && (h = v.as_h?)
      h.each_with_object({} of String => String) { |(k, val), acc| acc[k] = val.to_s }
    end

    private def persist : Nil
      return if @nullified
      if signed_session?
        payload = Hash(String, ActiveSupport::MessageVerifier::MetadataScalar).new
        @data.each { |k, v| payload[k] = v }
        @cookies.signed.set(KEY, payload)
      else
        @cookies[KEY] = Base64.strict_encode(@data.to_json)
      end
    end

    private def decode_legacy(raw : String) : Hash(String, String)
      json = Base64.decode_string(raw)
      JSON.parse(json).as_h.each_with_object({} of String => String) do |(k, v), h|
        h[k] = v.to_s
      end
    rescue
      {} of String => String
    end
  end

  class Flash
    KEY = "crails_flash"

    @current : Hash(String, String)
    @next : Hash(String, String) = {} of String => String

    def initialize(@cookies : Cookies)
      @current = {} of String => String
      if (raw = @cookies[KEY]?)
        # чтение: подписанная cookie, при провале — legacy Base64-JSON
        @current = read_signed(raw) || decode_legacy(raw)
      end
      @cookies.delete(KEY) # flash is read once
    end

    # Rails-семантика: значение видно в текущем запросе (рендер без
    # редиректа) И переносится на следующий, если его не прочитали.
    def []=(key : String | Symbol, value : String) : Nil
      k = key.to_s
      @current[k] = value
      @next[k] = value
      persist
    end

    # Read the flash; reading marks the key used (Rails: sweep) — a value
    # shown in the current request is not repeated on the next one.
    def [](key : String | Symbol) : String?
      k = key.to_s
      v = @current[k]?
      persist if v && @next.delete(k)
      v
    end

    def []?(key : String | Symbol) : String?
      self[key]
    end

    # Shown on the CURRENT request only.
    def now(key : String | Symbol, value : String) : Nil
      @current[key.to_s] = value
    end

    def key?(key : String | Symbol) : Bool
      @current.has_key?(key.to_s)
    end

    # Rails: discard удаляет ключ целиком — и из текущего показа, и из
    # переноса на следующий запрос.
    def discard(key : String | Symbol) : Nil
      k = key.to_s
      @current.delete(k)
      persist if @next.delete(k)
    end

    def keep(key : String | Symbol) : Nil
      if v = @current[key.to_s]?
        @next[key.to_s] = v
        persist
      end
    end

    private def signed_flash? : Bool
      !!ActionController.cookies_secret_key_base
    end

    private def read_signed(raw : String) : Hash(String, String)?
      return nil unless signed_flash?
      return nil unless (v = @cookies.signed[KEY]) && (h = v.as_h?)
      h.each_with_object({} of String => String) { |(k, val), acc| acc[k] = val.to_s }
    end

    private def persist : Nil
      if @next.empty?
        @cookies.delete(KEY)
      elsif signed_flash?
        payload = Hash(String, ActiveSupport::MessageVerifier::MetadataScalar).new
        @next.each { |k, v| payload[k] = v }
        @cookies.signed.set(KEY, payload)
      else
        @cookies[KEY] = Base64.strict_encode(@next.to_json)
      end
    end

    private def decode_legacy(raw : String) : Hash(String, String)
      JSON.parse(Base64.decode_string(raw)).as_h.each_with_object({} of String => String) do |(k, v), h|
        h[k] = v.to_s
      end
    rescue
      {} of String => String
    end
  end
end
