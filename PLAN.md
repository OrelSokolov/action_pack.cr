# action_pack.cr — порт ActionPack (контроллеры, роутинг, params)

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

Неймспейсы: `ActionController`, `ActionDispatch` — 1:1.

## Статус (Iteration 9 — ActionController::Live / SSE; 2026-10-06)

Порт `action_controller/metal/live.rb` actionpack 8.1.4 —
стриминг-first: chunked/SSE c backpressure и отменой fiber'а экшена
при disconnect клиента (фундамент ai-app-бутстрапа ECOSYSTEM.md).
`src/live.cr`; оракул `oracle/live_cases.rb` →
`oracle/live_expected.yml` (28 кейсов: in-process SSE-wire +
Buffer-семантика, транспорт на живом Puma 6.6.1 — chunked-фрейминг,
заголовки первого write, send_stream, ошибки до/после commit,
HTTP/1.0, disconnect); зеркало `railties.cr/spec/live_spec.cr`
**28/28** (транспорт — полный CRails-стек за реальным HTTP::Server,
сырые TCP-сокеты).

Сделано:
- `Live::Stream` (порт Live::Buffer) — буфер queue_size=10
  (SizedQueue-семантика на `Sync::Mutex` + 2 CondVar): заполненный
  буфер блокирует пишущий fiber — backpressure; `write/writeln`
  возвращают bytesize, первая запись коммитит заголовки
  (Cache-Control ||= no-cache, Content-Length удаляется);
- `abort` (клиент отвалился) — буфер очищается, заблокированный И
  следующий `write` поднимает `ClientDisconnected` (RuntimeError,
  1:1) — так отменяется fiber экшена; `ignore_disconnect`,
  `on_error/call_on_error`, `close` (sentinel), `connected?`;
- `Live::SSE(T)` — wire-формат побайтово: опции в порядке
  PERMITTED_OPTIONS (retry, event, id), data-строки с продолжением
  `\ndata: `, не-строки JSON (`to_json` ↔ ActiveSupport::JSON);
- экшен в отдельном fiber'е (`__live_dispatch`, перекрывает хук
  Base через include), pump — в запросном: заголовки на первом
  write (аналог await_commit), каждый write+flush = chunk-фрейм;
  ошибка сокета → abort → отмена; исключение до коммита — наружу
  (500 в лестнице ShowExceptions), после — call_on_error + close;
- `send_stream(filename:, disposition:, type:)` — CT/CD + yield
  стрима, ensure close; `response.stream`/`live_stream` на
  reopened `HTTP::Server::Response`; implicit render пропускается,
  если стрим уже закоммичен;
- кодоген `__run_action` обёрнут в `__live_dispatch` (без include —
  прозрачный yield).

Отклонения (в шапке src/live.cr): IOError ↔ IO::Error;
ActionView-completion при исключении после commit не пишется
(совпадает с наблюдаемым поведением оригинала — оракул
transport_error_after_commit_partial); abort будит заблокированного
продюсера немедленно (MRI SizedQueue может держать поток в push);
`id: 0` валиден (Ruby falsy-quirk не воспроизводим); SSE не-строки —
std `to_json`.

Bench `bench/results/402-sse.md` (bench/crails_sse + rails_sse):
fanout 50×2000 SSE ~482–622k events/s vs Rails+Puma 31–41k (~15×),
chunked ~710–887k chunks/s vs ~115k (~6–7×), first-token (d=1ms)
1.16 vs 1.97 ms, disconnect-storm 200: отмена за 120 мс / RSS 22 МБ
(1000 коннектов — 264 мс / 58 МБ).

## Статус (Iteration 15 — HTTP-кэширование fresh_when/stale?; база Iteration 14, 2026-10-05)

Спеки: `make spec` — **99 examples, 0 failures** (91 прежних + 8
conditional_get). Оракул `oracle/conditional_get_cases.rb` →
`oracle/conditional_get_expected.yml` (20 кейсов, rails 8.1.4
throwaway-app cо временным FwController; рендер после fresh_when при
fresh-запросе — DoubleRenderError, поэтому паттерн
`render ... unless performed?`); зеркало `spec/conditional_get_spec.cr`.

ConditionalGet (`src/conditional_get.cr`) — порт
`action_controller/metal/conditional_get.rb` +
`action_dispatch/http/cache.rb`. Сделано:
- `fresh_when(etag:|weak_etag:|strong_etag:|last_modified:|public:)` и
  `stale?` (инверсия); fresh → `head :not_modified` (пустое тело,
  performed)
- weak ETag `W/"<sha256[0,32]>"` (ActiveSupport::Digest: SHA256 → 32
  hex; expand_cache_key = join "/"), strong — без W/;
  Last-Modified httpdate "Thu, 01 Jan 2026 12:00:00 GMT"
- fresh? — **strict_freshness** (дефолт Rails 8.1 load_defaults,
  подтверждён оракулом fw_both_inm_wins_304): If-None-Match присутствует
  → только ETag-сравнение (список через ",", точное совпадение c W/ или
  "*"), If-Modified-Since игнорируется; иначе If-Modified-Since >=
  Last-Modified
- Cache-Control: public: true → "public"; иначе при выставленном ETag —
  "max-age=0, private, must-revalidate" (в Rails ставит Rack::ETag —
  вшито сюда, documented deviation)
- Отклонения: record-валидаторы (fresh_when @article) и template-digest
  не портированы (etag — строка); expires_in/http_cache_forever/no_store
  не из этого оракула; битые If-Modified-Since даты — nil (как
  `Time.httpdate rescue nil`)
- ActionController::Live / SSE — не портированы **на момент этой
  итерации** (см. статус Iteration 9 выше)

## Статус (Iteration 14 — cookies.signed/encrypted/permanent; база Iteration 13, 2026-10-05)

Спеки: `make spec` (CRAILS_VIEWS=spec/fixtures/app/views) —
**91 examples, 0 failures** (58 прежних + 33 cookies: 31 оракул-кейс
`oracle/cookies_cases.rb` → `oracle/cookies_expected.yml` (снят с
actionpack 8.1.4), реверс через настоящий гем `oracle/verify_cookies.rb`
+ 4 юнита). Все задействованные шарды зелёные: active_support 319,
railties 167, active_storage 57, action_view 151, turbo (`make spec`).

Cookies-слой (`src/cookies.cr`) — порт
`lib/action_dispatch/middleware/cookies.rb` 8.1.4. Сделано:
- `cookies.set(name, value, expires:/path:/domain:/secure:/httponly:/
  same_site:)` — атрибуты Set-Cookie с порядком и форматом Rack
  (domain, path, [max-age,] expires, httponly, secure, samesite;
  expires httpdate "Tue, 15 Oct 2030 05:00:00 GMT"); `secure: true`
  поверх plain HTTP дропает cookie; `delete(name, path:, domain:)` —
  value=""; max-age=0; expires=epoch
- под-jar'ы `cookies.signed` / `cookies.encrypted` / `cookies.permanent`
  (+ цепочки `.permanent.signed` — permanent ставит cookie-level
  expires=20 лет ПОСЛЕ подписи, поэтому message-level exp отсутствует,
  как в геме); purpose-изоляция `"cookie.#{name}"` c fallback-чтением
  без purpose (AbstractCookieJar#[]); CookieOverflow > 4096 байт
- wire ПОБАЙТОВО совпадает с гемом: signed → MessageVerifier(SHA1,
  legacy-конверт, ключ KeyGenerator(secret, iterations: 1000).
  generate_key("signed cookie")); encrypted → MessageEncryptor
  aes-256-gcm (generate_key("authenticated encrypted cookie", 32));
  legacy-конверт `{"_rails":{"message":b64(json),"exp":..,"pur":..}}` —
  это формат и приложения (NullSerializer не входит в
  ENVELOPE_SERIALIZERS, `use_message_serializer_for_metadata` на cookies
  не действует — проверено по исходникам и снятием оракула с флагом)
- секрет: `ActionController.cookies_secret_key_base=` (railties выставит
  на буте) / ENV["SECRET_KEY_BASE"]; без секрета signed/encrypted —
  RuntimeError; session/flash при наличии секрета едут в подписанной
  cookie (purpose "cookie.crails_session"/"cookie.crails_flash"), читают
  оба формата (переходный режим: legacy Base64-JSON читается всегда,
  пишется только без секрета)
- отклонения (задокументированы в шапке cookies.cr): Set-Cookie пишется
  сразу в response.headers (нет отложенного commit); https-детект по
  X-Forwarded-Proto (HTTP::Server не знает о TLS-терминации); SameSite
  по умолчанию не инжектится (railties-территория); cookie-verifier
  понимает только SHA1/SHA256.

## Статус (Iteration 13 — around_action; база Iteration 12, 2026-10-05)

Спеки: `CRAILS_VIEWS=spec/fixtures/app/views crystal spec` —
**58 examples, 0 failures** (11 http/routing, 28 strong params
с оракулом `oracle/params_cases.rb` → `oracle/params_expected.yml`
(снят с actionpack 8.1.4), 18 controllers (вкл. 4 around), 1 rate_limit).

around_action (Iteration 13, 2026-10-05): фильтры, оборачивающие экшен.
Сделано:
- `around_action :method` / блочная форма `around_action do ... end`,
  опции `only:/except:/if:/unless:` (общий с before_action макрос
  `__callback_condition`); фильтр обязан вызвать `yield` (продолжение
  цепочки → экшен)
- порядок как в Rails: before → around (снаружи экшена) → экшен →
  пост-код around; редирект в before пропускает around целиком
- кодеген: по одному методу `__around_step_N` на шаг (один рекурсивный
  метод ловит "recursive block expansion" Crystal); имена колбэков
  (before/around/rescue-обработчики) исключены из action-набора —
  иначе around-фильтр с `yield` пытался бы диспетчеризоваться как экшен
- E2E-паттерн per-user timezone: `around_action :set_time_zone` где
  `set_time_zone` делает `Time.use_zone(user.timezone) { yield }` —
  ответ рендерится в зоне пользователя, после запроса зона
  восстановлена (fiber-local override из active_support.cr)

## Статус (Iteration 10 — type-safe params + OpenAPI; база Iteration 3, 2026-10-02)

Спеки: `CRAILS_VIEWS=spec/fixtures/app/views crystal spec` (или
`make spec`) — **153 examples, 0 failures** (11 http/routing, 28 strong
params, 14 controllers, 1 rate_limit unit, 20 conditional_get, 8
conditional-get-2, 20 rate-limit oracle, 33 cookies, + Iteration 10:
42 typed-params oracle + 5 typed-params units + 7 OpenAPI; E2E в
railties.cr/spec/typed_params_spec.cr — 4/4: 422-лестница + /openapi.json
на живом сервере).

TypedParams (Iteration 10, 2026-10-06): `src/typed_params.cr` —
compile-time типизированные параметры экшенов. Оракул —
**dry-schema 1.13.4** (`Dry::Schema.Params`, индустриальный стандарт
типизированных параметров Ruby): `oracle/typed_params_cases.rb` →
`typed_params_expected.yml` — 42 кейса (verdict + коарсинг-вывод +
дерево ошибок), зеркало `spec/typed_params_oracle_spec.cr` 42/42
без правок кейсов. Сделано:
- DSL `typed_params(:create) do required :title, String, min_size: 3
  ... optional :admin, Bool? ... required :author do ... end end`;
  макрос генерирует класс `CreateParams` с типизированными геттерами
  (`fp.title : String`, `fp.author.name` — compile-checked) +
  хелпер `create_params` в контроллере (невалид →
  `TypedParams::Invalid` → 422 JSON-ошибки в railties-лестнице)
- семантика 1:1 с dry-schema: `required/optional` × `filled/maybe`,
  коарсинг dry-types Params (bool-таблицы 1:1, "33"→33, ""→nil/[]
  для maybe/array, float→int truncate), ошибки "is missing"/"must be
  filled"/"must be an integer"/size-границы, ошибки элементов массива
  по индексам, output-дерево (valid — коарснутые, invalid — raw)
- рекурсия вложенных `do`-блоков через отложенные macro-вызовы
  (`tp_class`) — в макро-языке Crystal нет while/рекурсии
- OpenAPI codegen: `src/openapi.cr` — документ 3.0.3 из таблицы роутов
  + реестра схем (`:id`→`{id}` path params, operationId, requestBody
  JSON Schema для POST/PATCH/PUT, query-параметры для GET; 3.0.3, не
  3.1 — `nullable: true`, widest tooling). Реверс-валидация настоящим
  openapi3_parser 0.10.1 (`oracle/verify_openapi.rb`, паттерн
  verify_*): документ из спека валиден. Раздача — встроенный
  `CRails::OpenApiController`, монтирование одной строкой
  `openapi "/openapi.json"` в drawer'е роутов
- бенч `bench/results/205-typed-params.md`: ~30× vs dry-schema
  (887k vs 30k ops/s), ~11.6× vs Ruby-permit; внутри Crystal ~0.58×
  от нетипизированного permit

Отклонения (typed params, задокументированы):
- DSL отличается от dry-schema предикатов (семантика зеркалится);
  сообщение-тексты скопированы с dry для покрытого подмножества
- `" 5".to_i?` → nil (Ruby `Integer(" 5")` → 5, whitespace)
- ошибки/вывод — boxed `TypedParams::Any` (Object нельзя в генерик);
  типобезопасный API — геттеры
- query-параметры OpenAPI: вложенные hash-поля не описываются
  (form-encoding `a[b]` не выражается в OpenAPI query)

CSRF (Iteration 12, 2026-10-05): `RequestForgeryProtection` — порт
`lib/action_controller/metal/request_forgery_protection.rb` 8.1.4.
Оракул `oracle/csrf_cases.rb` → `oracle/csrf_expected.yml` — 28 кейсов
с настоящего actionpack 8.1.4 (bare-контроллеры + Cookies/CacheStore-
сессия + Flash + ShowExceptions, реальные cookie-jar'ы), зеркало
`railties.cr/spec/csrf_spec.cr` 28/28. Сделано:
- `protect_from_forgery with: :exception|:null_session|:reset_session`
  (`only:/except:`, дефолт `:null_session` как в геме), макрос
  `skip_forgery_protection`; `InvalidAuthenticityToken`/
  `InvalidCrossOriginRequest` → 422 (лестница railties)
- токены 1:1 по wire-формату: real 32 байта в сессии, BREACH-маска
  (pad XOR raw), глобальный HMAC-SHA256(real, "!real_csrf_token"),
  per-form HMAC-SHA256(real, "#{path}##{method}") при
  `per_form_csrf_tokens`; приём param `authenticity_token` ИЛИ хедера
  `X-CSRF-Token`; fixed-length compare (Crypto::Subtle)
- origin-проверка (`forgery_protection_origin_check`, off по умолчанию);
  after-проверка JS-ответов не-XHR (InvalidCrossOriginRequest)
- `form_with`/`form_tag` вставляют hidden-поле токена (не-GET формы,
  `authenticity_token: false` отключает); `csrf_meta_tags` (CsrfHelper);
  `Session#nullify!` — null_session без перезаписи клиентской сессии
- генератор `crails new`: ApplicationController с
  `protect_from_forgery with: :exception` + `<%= csrf_meta_tags %>` в
  layout (E2E: POST без токена → 422, с X-CSRF-Token из meta → 200)
- по пути чинены два латентных бага: `skip_before_action` не работал
  (Symbol#stringify в FILTERS даёт `:name` — нормализовано;
  интерполяция `:"__skip_#{name}"` не разрешалась) и cookie round-trip
  сессии (write кодировал `encode_www_form`, read не декодировал —
  крос-реквестная сессия не выживала)

DataStreaming (P2-слот закрыт, 2026-10-05): порт `metal/data_streaming.rb`
+ `action_dispatch/http/content_disposition.rb` 8.1.4 — оракул 12 кейсов
(`oracle/data_streaming_cases.rb` → `data_streaming_expected.yml`),
зеркало `railties.cr/spec/data_streaming_spec.cr` 13/13. Сделано:
- `send_data`/`send_file`: filename/type/disposition/status/
  content_type/url_based_filename; CT без charset; вывод типа по
  расширению (подмножество Rack::Mime, дефолт octet-stream)
- Content-Disposition двойной формат (`disp; filename="<ascii>";
  filename*=UTF-8''<rfc5987>`) — percent-escape, не-ASCII в ascii-имени
  → `%3F` (как bare-гем без правил транслитерации)
- `Content-Transfer-Encoding: binary`; отсутствующий файл →
  `ActionController::MissingFile` → 404 в railties-лестнице
  (rescue_responses Rails)
- отклонения: Range для send_file — P2, type: — String (не Symbol)

Сделано (Iteration 3):
- strong parameters: `Parameters` (`require/permit/expect/to_h`;
  `[]`/`[]?`, парсинг query + JSON/form тел, вложенные форм-ключи
  `post[title]=x`)
- контроллеры: `before_action/skip_before_action` (only/except/if/
  unless), `rescue_from`, `respond_to`, `head`, `redirect_back`,
  cookies/session (cookie store)/flash (read-once)
- рендер action-шаблонов `.html.erb` через action_view.cr: шаблоны
  приложения сканируются и компилируются на этапе сборки (CRAILS_VIEWS
  или `app/views`); партиалы объявляются приложением через
  `compile_partials` в ApplicationController (типы локалей известны
  только приложению)
- `.json.jbuilder`-шаблоны экшенов (implicit render при format=json —
  `?format=json` или `Accept: application/json` — и явный
  `render(template: "posts/show.json.jbuilder")`): кодоген зовёт
  `JbuilderHandler.call` из шарда jbuilder.cr (~/myshards), приложение с
  такими шаблонами обязано `require "jbuilder_cr"`; оракул и зеркало —
  там же (oracle/cases_controller.rb, spec/railtie_spec.cr). Явный рендер
  — только именованный аргумент: позиционная строка render("...") занята
  телом JSON-ответа, а одноимённая позиционная перегрузка ломает
  именованную диспетчеризацию `render(json:)` (квирк Crystal 1.21)

Отклонения (задокументированы):
- `permit`/`expect` принимают вложенные фильтры hash-аргументом:
  `permit(:title, {"author" => [:name]})` — `**opts` с гетерогенными
  значениями роняет компилятор Crystal 1.21
- session/flash — cookie store без подписи/шифрования (подписанные/
  зашифрованные — P2); CSRF-слой есть (Iteration 12, см. выше)
- CSRF-отклонения: конфиг глобальный (config.action_controller.*-стиль),
  не per-class мутаторы; `with:` — Symbol без кастомных strategy-классов;
  `store: :cookie` — P2; form_options — именованные аргументы
  `form_authenticity_token(action:, method:)`, не хеш
- `send_file`/`send_data` — готовы (DataStreaming, см. выше);
  `cookies.signed/encrypted`, HTTP-кэш — P2

## Цель

Контроллеры и роутинг, ощущаемые как Rails: `before_action`,
`resources :posts`, `params.require(...).permit(...)`, `render json:`,
`redirect_to`, flash/session/cookies.

## API 1:1

### Контроллеры (P0)
- `class PostsController < ApplicationController` ( ApplicationController
  < `ActionController::Base`)
- `before_action :authenticate, only: [:index] / except:, if:, unless:`
  (+ `prepend_/skip_`) — макрос с `**opts`
- `around_action :method / do ... end` (фильтр вызывает `yield`),
  те же `only:/except:/if:/unless:`
- `render plain:/html:/json:/template:/partial:/layout:, status: (символ
  или число), formats:, locals:`, `render_to_string`, `head :no_content`
- `redirect_to path, notice:/alert:`, `redirect_back fallback_location:`,
  `redirect_back_or_to`
- `respond_to do |format| format.html { } format.json { } end`
  (фикс-методы вместо method_missing-коллектора)
- `rescue_from Exception, with:` (макрос)
- `request.headers/method/get?/post?/format/remote_ip/user_agent/
  original_url/query_parameters/body/authorization`; `response.headers/
  status/...`
- `send_data/send_file (filename:, type:, disposition:, range:)`

### Strong params (P0)
`params[:id]`, `params[:person][:name]`, `require(:post)` (raise
ParameterMissing → 400), `permit(:title, :body, tags: [], addresses:
[:id, :zip], preferences: {})`, `expect`, `to_h/to_unsafe_h/slice/except/
dig/fetch`. Ключи Symbol|String без разницы (аппроксимация
HashWithIndifferentAccess).

### Cookies / session / flash (P1)
`cookies[:k] = v` (`expires:, path:, domain:, secure:, httponly:,
same_site:`), `cookies.permanent/signed/encrypted`, `cookies.delete`;
`session[:user_id]`, `reset_session`; `flash[:notice]/flash.now/keep/
discard`, `add_flash_types :warning` (макрос).

### Роутинг (P0)
- `CRails.application.routes.draw do ... end` в `config/routes.cr`
- `root "welcome#index"`, `get/post/patch/put/delete path, to:`,
  `match via:`, `redirect`
- `resources :posts (only:, except:, shallow:, concerns:, param:, path:,
  as:, module:)`, `resource`, `member { } / collection { } / nested/
  shallow`, `namespace :admin`, `scope (path:, as:, module:, defaults:,
  constraints:)`, `constraints`, `defaults`, `concern/concerns`,
  wildcard `*path`, optional `foo(/bar)`
- Именованные хелперы `posts_path`, `edit_post_path(@post)`,
  `new_admin_post_url` — макрос-генерация (проверено зондом).
  Полиморфные массивы `url_for([:edit, @post])` — P2 (~70%).

### HTTP-кэш и стриминг (P2)
`fresh_when(etag:, last_modified:, public:)`, `stale?`, `expires_in`,
`http_cache_forever`; `ActionController::Live` на fiber'ах,
`response.stream.write/close`, `send_stream`.

## Реализация

- HTTP-слой: Crystal `HTTP::Server` + `HTTP::Handler`-цепочка = middleware
  стек с теми же операциями (`use/insert_before/insert_after/swap/delete`).
- Роутер: compile-time таблица + runtime матчинг сегментов;
  `*_path`-хелперы — макрос над `resources`/`get as:`.
- Конкурентность: fiber-per-connection (аналог threaded mode, но дешевле).
- `CRails.env` — enum с предикатами (`CRails.env.production?`).

## Фазы

- P0: маршруты (get/root/resources) + именованные хелперы, контроллеры
  (before_action, render/redirect, params require/permit), basic request.
- P1: cookies/session/flash (signed/encrypted), rescue_from, respond_to,
  send_data/file, middleware-стек API.
- P2: HTTP-кэширование, Live-стриминг, полиморфные урл-хелперы,
  `CRails.application.routes.draw` полный синтаксис.

## Готово, когда

scaffold-контроллер из Rails-туториала (`resources :posts` + CRUD +
notice-flash + strong params) компилируется после `rails→crails` замены
`Rails`→`CRails` (шаблоны остаются ERB).

## Зависимости

active_support.cr, railties.cr (boot), action_view.cr (render).
