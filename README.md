# action_pack.cr

A Crystal port of Rails **ActionPack 8.1.4** — controllers, routing, strong
parameters, cookies/session/flash, CSRF protection, HTTP caching and
streaming. Namespaces `ActionController` / `ActionDispatch` mirror the
original 1:1. Behavioral parity is verified against the real gem via
oracle specs (Ruby cases recorded with actionpack 8.1.4, replayed in
Crystal without edits).

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

## Installation

```yaml
dependencies:
  action_pack_cr:
    github: OrelSokolov/action_pack.cr
```

```sh
shards install
```

Requires Crystal >= 1.21.0. Works with `active_support.cr`, `action_view.cr`
and `railties.cr` (boot/middleware ladder).

## Usage

```crystal
class ApplicationController < ActionController::Base
end

class PostsController < ApplicationController
  before_action :authenticate, only: [:index]

  def index
    @posts = Post.all
  end

  def create
    post = Post.new(params.require(:post).permit(:title, :body))
    if post.save
      redirect_to posts_path, notice: "Created"
    else
      render :new, status: :unprocessable_entity
    end
  end
end

# config/routes.cr
CRails.application.routes.draw do
  resources :posts
  root "welcome#index"
end
```

Run the suite with `make spec` (or
`CRAILS_VIEWS=spec/fixtures/app/views crystal spec`).

## Feature comparison vs actionpack 8.1.4

### Controllers & callbacks

| Feature | Original (actionpack) | Port (action_pack.cr) | Status |
|---|---|---|---|
| `ActionController::Base` inheritance | ✅ | Same class hierarchy | ✅ |
| `before_action` / `skip_before_action` (`only:/except:/if:/unless:`) | ✅ | Same options via macro | ✅ |
| `around_action` (symbol + block, `yield` continues the chain) | ✅ | Same; one generated `__around_step_N` per step (Crystal macro recursion limit) | ✅ |
| `rescue_from ... with:` | ✅ | Macro-based | ✅ |
| `respond_to do \|format\| ... end` | ✅ | Fixed `format.html`/`format.json` methods instead of a `method_missing` collector | 🔶 |
| `render plain:/html:/json:/template:/partial:/layout:, status:, formats:, locals:`, `render_to_string`, `head` | ✅ | Same | ✅ |
| `.json.jbuilder` action templates (implicit render for `format=json`) | ✅ | Via jbuilder.cr; explicit render is named-arg only (`render(template:)`) — positional `render("...")` is the JSON body | 🔶 |
| `redirect_to`, `redirect_back fallback_location:`, `redirect_back_or_to`, `notice:/alert:` | ✅ | Same | ✅ |

### Routing

| Feature | Original | Port | Status |
|---|---|---|---|
| `root`, `get/post/patch/put/delete ... to:`, `match via:`, `redirect` | ✅ | Same | ✅ |
| `resources` / `resource` (`only:, except:, shallow:, concerns:, param:, path:, as:, module:`), `member`/`collection`, nested/shallow routes | ✅ | Compile-time route table + runtime segment matching | ✅ |
| `namespace`, `scope` (`path:, as:, module:, defaults:, constraints:`), `concern/concerns`, wildcard `*path`, optional `foo(/bar)` | ✅ | Same | ✅ |
| Named helpers `posts_path`, `edit_post_path(@post)` | ✅ | Macro-generated from `resources`/`get as:` | ✅ |
| Polymorphic array URLs `url_for([:edit, @post])` | ✅ | ~70% | 🔶 |

### Strong parameters

| Feature | Original | Port | Status |
|---|---|---|---|
| `params[:id]`, `require(:post)` (raises `ParameterMissing` → 400), `permit`, `expect`, `to_h/to_unsafe_h/slice/except/dig/fetch` | ✅ | Same; query + JSON/form body parsing, nested form keys `post[title]=x` | ✅ |
| Nested filters `permit(:title, tags: [], addresses: [:id])` | ✅ | Hash-argument form `permit(:title, {"author" => [:name]})` — `**opts` with heterogeneous values breaks Crystal 1.21 | 🔶 |
| `HashWithIndifferentAccess` semantics | ✅ | Symbol\|String keys without distinction (approximation) | 🔶 |

### Cookies / session / flash

| Feature | Original | Port | Status |
|---|---|---|---|
| `cookies.set` with `expires:/path:/domain:/secure:/httponly:/same_site:`, `cookies.delete` | ✅ | Rack-identical Set-Cookie attribute order/format | ✅ |
| `cookies.signed` / `cookies.encrypted` / `cookies.permanent` (+ chains) | ✅ | Byte-identical wire format (MessageVerifier SHA1 / AES-256-GCM, legacy `{"_rails":...}` envelope), purpose isolation, `CookieOverflow` > 4096 B | ✅ |
| session / flash in signed cookie | ✅ | With `SECRET_KEY_BASE` set; legacy Base64-JSON always readable (transition mode) | 🔶 |
| `flash[:notice]/now/keep/discard`, `add_flash_types` | ✅ | Same | ✅ |

### CSRF protection

| Feature | Original | Port | Status |
|---|---|---|---|
| `protect_from_forgery with: :exception/:null_session/:reset_session`, `skip_forgery_protection` | ✅ | Token wire format 1:1 (BREACH mask, global + per-form HMAC-SHA256, `Crypto::Subtle` compare); param or `X-CSRF-Token` header | ✅ |
| Origin check, JS-response `InvalidCrossOriginRequest` | ✅ | Off by default, as in the gem | ✅ |
| Per-class mutators, custom strategy classes | ✅ | Global config only; `with:` is a Symbol | ❌ (equivalent: global `ActionController.*` setters) |

### HTTP caching & streaming

| Feature | Original | Port | Status |
|---|---|---|---|
| `fresh_when` / `stale?` (etag/weak/strong/last_modified/public) | ✅ | strict_freshness semantics (Rails 8.1 default), weak ETag `W/"sha256[0,32]"` | ✅ |
| `expires_in`, `http_cache_forever`, `no_store` | ✅ | Not ported | ⬜ |
| Record validators in `fresh_when(@article)`, template digest | ✅ | `etag:` accepts a String only | ❌ (equivalent: precompute the digest string) |
| `send_data` / `send_file` (filename/type/disposition), RFC 5987 Content-Disposition | ✅ | Subset of Rack::Mime for type lookup; missing file → 404 | ✅ |
| `send_file` Range requests | ✅ | Not ported | ⬜ |
| `ActionController::Live` / SSE (`response.stream`, `send_stream`) | ✅ | Fiber-based: backpressure (buffer queue_size=10), client-disconnect cancellation, byte-exact SSE wire format | ✅ |

### Beyond parity (not in actionpack)

| Feature | Port | Status |
|---|---|---|
| TypedParams — compile-time typed action params | DSL mirrors dry-schema 1.13.4 semantics (42/42 oracle cases); invalid params → 422 JSON errors | ✅ |
| OpenAPI 3.0.3 codegen from the route table (`openapi "/openapi.json"`) | Verified with openapi3_parser 0.10.1 | ✅ |
| Rate limiting | 20/20 oracle cases | ✅ |

## Deviations & Crystal-specific notes

- Set-Cookie headers are written directly to `response.headers` (no deferred
  commit); HTTPS detection uses `X-Forwarded-Proto` (Crystal's
  `HTTP::Server` is unaware of TLS termination); SameSite is not injected
  by default (railties territory); the cookie verifier supports only
  SHA1/SHA256 digests.
- In `Live`: `IOError` maps to `IO::Error`; ActionView completion is not
  written when an exception fires after commit (matches observed gem
  behavior); `abort` wakes a blocked producer immediately; `id: 0` is valid
  (the Ruby falsy quirk is not reproducible); SSE non-String payloads use
  stdlib `to_json`.
- `permit`/`expect` nested filters use a Hash argument (see table).
- HTTP layer is Crystal `HTTP::Server` with an `HTTP::Handler` chain
  exposing the same stack operations (`use/insert_before/insert_after/
  swap/delete`); concurrency is fiber-per-connection.
- Benchmarks (`bench/results/`): SSE fanout ~482–622k events/s vs
  Rails+Puma 31–41k (~15×); chunked ~710–887k chunks/s (~6–7×); typed
  params ~30× vs dry-schema.

## Testing

```sh
make spec   # or: CRAILS_VIEWS=spec/fixtures/app/views crystal spec
```

Oracle specs: Ruby cases in `oracle/*_cases.rb` are recorded with the real
actionpack 8.1.4 into `oracle/*_expected.yml`, then replayed byte-for-byte
by the Crystal mirror in `spec/`. Transport-level specs (Live/SSE, CSRF,
data streaming, typed params E2E) live in `railties.cr/spec/` against a
real `HTTP::Server`.
