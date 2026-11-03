// Command sdkgen writes Alpr.sh's SDKs from the public API's contract.
//
//	go run ./cmd/sdkgen                                  # every language
//	go run ./cmd/sdkgen -language go                     # one
//	go run ./cmd/sdkgen -sync ../alpr.sh/docs/contracts/api.openapi.json
//
// -sync copies the contract alpr.sh exports into openapi.json first, so the
// contract the SDKs were written from is kept beside them.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/alpr-sh/sdk/generator"
)

func main() {
	spec := flag.String("spec", "openapi.json", "the public API's contract")
	sync := flag.String("sync", "", "a contract to copy into -spec before generating")
	language := flag.String("language", "", "one language; every language when empty")
	out := flag.String("out", ".", "the directory that holds VERSION and <language>/")
	flag.Parse()
	if *sync != "" {
		raw, err := os.ReadFile(*sync)
		if err == nil {
			err = os.WriteFile(*spec, raw, 0o644)
		}
		if err != nil {
			fail("sdkgen: sync the contract:", err)
		}
	}
	version, err := os.ReadFile(filepath.Join(*out, "VERSION"))
	if err != nil {
		fail("sdkgen: read the SDK version:", err)
	}
	ir, err := generator.Load(*spec, strings.TrimSpace(string(version)))
	if err != nil {
		fail(err)
	}
	languages := []string{*language}
	if *language == "" {
		languages = languages[:0]
		for name := range generator.Languages {
			languages = append(languages, name)
		}
		sort.Strings(languages)
	}
	for _, name := range languages {
		if err := generator.Generate(ir, name, filepath.Join(*out, name)); err != nil {
			fail(err)
		}
		fmt.Println("sdkgen: wrote", filepath.Join(*out, name))
	}
}

func fail(args ...any) {
	fmt.Fprintln(os.Stderr, args...)
	os.Exit(1)
}
