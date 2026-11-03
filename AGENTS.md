# Working in this repository

Alpr.sh's SDKs, one package per language, generated from the public API's
contract the way Polar generates its own. Read this before changing anything.
The product is Brazil-only: READMEs and docs are in Brazilian Portuguese;
identifiers, JSON keys, comments and commits are in English.

## What is generated and what is written

- `go/`, `typescript/`, `python/`, `php/`, `ruby/`, `java/`, `csharp/`,
  `elixir/`, `dart/`, `rust/` and `swift/` are **output**. The generator
  empties each one and writes it again, so an edit there is lost on the next
  run. Change the template instead.
- `generator/templates/<language>/` is where every SDK's hand-written part
  lives: client, errors, pagination, multipart upload, webhooks, tests,
  README. A `.tmpl` file is rendered with the IR; any other file is copied.
  `_dot_` in a name becomes `.`; `__model__`, `__service__` and `__webhook__`
  write the file once per model, service or webhook group. The TypeScript
  monitor screens (`src/monitor`, `src/react`, `src/vue`, `src/svelte`,
  `src/next`, `src/htmx`) and `examples/` are such copied files: regenerating
  keeps them.
- `generator/` (Go) reads `openapi.json` into a language-neutral IR
  (`ir.go`) and renders it (`emit.go`, `lang_<language>.go`). The IR reads this
  API's shapes: an operation `service:method`; `multipart/form-data` photos
  (`Method.Multipart`, a `binary` field); an object answer; a `{data: [...]}`
  list; a `{data: [...], next}` page over a cursor query parameter; flat
  webhook payloads told apart by `event`. It keeps only the models the
  services and the signed webhooks reach, and skips the webhooks that carry
  another delivery's headers (the previous platform's, the partners').
- `openapi.json` is copied from alpr.sh (`docs/contracts/api.openapi.json`).
  Never edit it here: change the API in alpr.sh, export it, then
  `go run ./cmd/sdkgen -sync ...`.
- `generator/testdata/webhook-vectors.json` holds the webhook vectors every
  language's tests use. Change it only with the signing scheme.

## The gates

`./check.sh` runs all of them; nothing is finished until it exits zero. A
language whose toolchain is missing is skipped with a warning and listed at the
end; CI sets `CHECK_STRICT=1` so a skip fails there.
- generator: gofmt, vet, test, regenerate;
- go: vet and test;
- typescript: `tsc --noEmit`, then `npm test` (build, then `node --test` on
  the API, the monitor core and every framework adapter);
- python: unittest and `mypy --strict` on 3.11;
- php: `tests/run.php` and PHPStan level 8;
- ruby: minitest under `ruby -w`;
- java: `mvn verify` (`-Xlint:all -Werror`);
- csharp: `dotnet test`, warnings as errors;
- elixir: compile and test with `--warnings-as-errors`;
- dart: `dart format`, `dart analyze --fatal-infos`, `dart test`;
- rust: `cargo fmt --check`, clippy `-D warnings`, `cargo test`;
- swift: `swift test` in `swift/` and `swift build` at the root (macOS only:
  CryptoKit and Network; CI runs it in its own macOS job).

`Package.swift` and `composer.json` at the root are hand-written, because
SwiftPM and Packagist resolve a package from the repository root; keep them in
step with `swift/Package.swift` and `php/composer.json`.

CI also fails when the committed SDKs differ from what the generator writes.

Use `$(go env GOROOT)/bin/gofmt`: a Homebrew gofmt on the PATH may be a newer
release that formats differently from CI.

## Rules

- Every SDK does the same thing, under the same version (`VERSION`). A feature
  goes into every language, with the same test in each, or into none.
- The API has no `Idempotency-Key` and the SDKs do not retry: a photo read
  spends a credit. Do not add either without the API doing it first.
- Webhook verification is exactly what alpr.sh signs (hesape's `webhook.Sign`,
  prefix `X-Alprsh`): HMAC-SHA256 of `timestamp.delivery-id.body`, the whole
  `whsec_...` secret as the key (not base64-decoded), `sha256=<hex>` values,
  several allowed during a rotation (at most 6, one malformed one refuses the
  request), 300 s tolerance. Change it with alpr.sh or not at all.
- No third-party runtime dependency where the language's standard library can
  do HTTP, JSON and HMAC. The two exceptions are deliberate: Dart uses `http`
  and `crypto` from dart.dev, and Rust uses serde, serde_json, ureq, hmac and
  sha2. Do not add others. The TypeScript frameworks (react, vue, svelte, next)
  are optional peer dependencies and dev dependencies only.
- The monitor never takes the workspace's API key to a browser: browser entry
  points (`monitor`, `react`, `vue`, `svelte`, `next/client`, `htmx/element`)
  must not reach `client.ts` or `monitor/server.ts`; a test checks it.
- Each SDK keeps its language's idiom for walking every page: Go `ListIter`,
  TypeScript async iterators, Python and Ruby `list_iter`, PHP generators,
  Java `Iterable`, C# `IAsyncEnumerable`, Elixir `list_stream`, Dart and Swift
  streams, Rust `Iterator`.
- Code, comments and commits are in English; the READMEs are in Brazilian
  Portuguese. Commits are authored by `Paulo R. Lima <paulorlima@hyz.is>` (Alpr.sh is a product), set with
  `git config` in the checkout, signed off (`-s`), without AI attribution.
  Agent instructions live only in this `AGENTS.md`.

## Names

The package is the GitHub repository: organization `alpr-sh`, package `sdk`.
npm `@alpr-sh/sdk`, Packagist `alpr-sh/sdk`, Maven `sh.alpr:sdk`, Go and Swift
`github.com/alpr-sh/sdk`; where a registry has no namespace, `alpr-sdk` (PyPI,
RubyGems, crates.io), `alpr_sdk` (Hex, pub.dev) and `AlprSh.Sdk` (NuGet). In
every registry the package belongs to the `alpr-sh` organization. Never rename
or add a package, and never publish, without the owner's confirmation: none
has been published and `VERSION` is a provisional `0.1.0` with no tag.

## Release

See `RELEASING.md` (nothing in it has been run). One version for every
language: bump `VERSION`, run `go run ./cmd/sdkgen` and `./check.sh`, commit
on `main`, then tag `vX.Y.Z` and `go/vX.Y.Z`.
