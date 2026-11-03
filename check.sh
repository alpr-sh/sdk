#!/bin/sh
# The gates every change passes: the generator and its tests, the SDKs being
# exactly what the generator writes, and each language's own tests and type
# checks.
#
# A language whose toolchain is not on this machine is skipped with a warning
# and listed at the end; it is never reported as passed. CHECK_STRICT=1 (CI)
# turns a skip into a failure. CHECK_DRIFT=1 (CI) also fails when a
# regenerated SDK differs from what is committed. MYPY and PHPSTAN name those
# tools when they are not on the PATH. Swift needs Apple's toolchain
# (CryptoKit, Network): it runs only on macOS, and SKIP_SWIFT=1 leaves it to
# the macOS CI job.
set -eu
cd "$(dirname "$0")"
export GOWORK=off

skipped=""

# have says whether every command is installed.
have() {
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || return 1
	done
}

# skip records a gate that did not run, and why.
skip() {
	echo "SKIPPED $1: $2" >&2
	skipped="$skipped
  $1: $2"
}

echo "== generator"
unformatted=$("$(go env GOROOT)/bin/gofmt" -l generator cmd go)
if [ -n "$unformatted" ]; then
	echo "not gofmt'd:"
	echo "$unformatted"
	exit 1
fi
go vet ./...
go test -count=1 ./...
go run ./cmd/sdkgen
if [ "${CHECK_DRIFT:-}" = 1 ] && [ -n "$(git status --porcelain -- openapi.json go typescript python php ruby java csharp elixir dart rust swift Package.swift)" ]; then
	echo "the SDKs differ from what the generator writes: run go run ./cmd/sdkgen and commit"
	git status --porcelain -- go typescript python php ruby java csharp elixir dart rust swift Package.swift
	exit 1
fi

echo "== go"
(cd go && go vet ./... && go test -count=1 ./...)

echo "== typescript"
if have node npm; then
	(cd typescript && npm ci --ignore-scripts --no-audit --no-fund --silent && npx tsc -p tsconfig.json --noEmit && npm test --silent)
else
	skip typescript "node and npm are not installed"
fi

echo "== python"
if have python3; then
	(cd python && PYTHONPATH=src python3 -m unittest discover -s tests)
	if have "${MYPY:-mypy}"; then
		(cd python && "${MYPY:-mypy}" --strict --python-version 3.11 src/alpr)
	else
		skip "python (mypy)" "mypy is not installed; set MYPY to its path"
	fi
else
	skip python "python3 is not installed"
fi

echo "== php"
if have php; then
	(cd php && php tests/run.php)
	if have "${PHPSTAN:-phpstan}"; then
		(cd php && "${PHPSTAN:-phpstan}" analyse --no-progress --level 8 src)
	else
		skip "php (phpstan)" "phpstan is not installed; set PHPSTAN to its path"
	fi
else
	skip php "php is not installed"
fi

echo "== ruby"
if have ruby; then
	(cd ruby && ruby -w -Ilib -Itest test/alpr_test.rb)
else
	skip ruby "ruby is not installed"
fi

echo "== java"
if have mvn java; then
	(cd java && mvn -q -B verify)
else
	skip java "java and mvn are not installed"
fi

echo "== csharp"
if have dotnet; then
	(cd csharp && dotnet test --nologo)
else
	skip csharp "dotnet is not installed"
fi

echo "== elixir"
if have mix elixir; then
	(cd elixir && mix compile --warnings-as-errors && mix test --warnings-as-errors)
else
	skip elixir "elixir and mix are not installed"
fi

echo "== dart"
if have dart; then
	(cd dart && dart pub get && dart format --output=none --set-exit-if-changed . && dart analyze --fatal-infos && dart test)
else
	skip dart "dart is not installed"
fi

echo "== rust"
if have cargo; then
	(cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)
else
	skip rust "cargo is not installed"
fi

if [ "${SKIP_SWIFT:-}" = 1 ]; then
	skip swift "SKIP_SWIFT=1"
elif have swift; then
	echo "== swift"
	swift=swift
	if command -v xcrun >/dev/null; then
		swift="xcrun swift"
	fi
	(cd swift && $swift test) && $swift build
else
	skip swift "swift is not installed"
fi

if [ -n "$skipped" ]; then
	echo
	echo "gates that did not run:$skipped" >&2
	if [ "${CHECK_STRICT:-}" = 1 ]; then
		exit 1
	fi
fi
echo
echo "check.sh: every gate that could run passed"
