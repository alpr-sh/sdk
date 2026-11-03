package generator

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// hostile is text a contract could carry to end a comment or a docstring and
// start code of its own: block and line comment terminators, a docstring
// quote, a new line, string interpolation, a backslash and a bidirectional
// override.
const hostile = "first */ BREAKOUT_A /* \"\"\" BREAKOUT_B '''\r\nBREAKOUT_C #{BREAKOUT_D} ${BREAKOUT_E} \\u000a \\ \" ‮ end"

// load reads the repository's contract after mutate has changed it.
func load(t *testing.T, mutate func(doc map[string]any)) (*IR, error) {
	t.Helper()
	raw, err := os.ReadFile("../openapi.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	mutate(doc)
	changed, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "openapi.json")
	if err := os.WriteFile(path, changed, 0o644); err != nil {
		t.Fatal(err)
	}
	return Load(path, "0.1.0")
}

func dig(doc map[string]any, keys ...string) map[string]any {
	node := doc
	for _, key := range keys {
		node = node[key].(map[string]any)
	}
	return node
}

// A description or a summary cannot leave its comment, in any language: what
// ends a comment is broken, a new line stays a comment line, and what a
// language reads inside a string is escaped.
func TestHostileTextStaysInsideItsComment(t *testing.T) {
	ir, err := load(t, func(doc map[string]any) {
		camera := dig(doc, "components", "schemas", "Camera")
		camera["description"] = hostile
		dig(camera, "properties", "name")["description"] = hostile
		dig(doc, "paths", "/api/v1/cameras", "get")["summary"] = hostile
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.ContainsAny(ir.Services[0].Methods[0].Summary, "\r\n") {
		t.Errorf("a summary spans lines: %q", ir.Services[0].Methods[0].Summary)
	}
	lineComments := map[string][]string{
		"go": {"//"}, "rust": {"///"}, "swift": {"///"}, "dart": {"///"}, "ruby": {"#"}, "csharp": {"///"},
	}
	for language := range Languages {
		out := t.TempDir()
		if err := Generate(ir, language, out); err != nil {
			t.Fatalf("%s: %v", language, err)
		}
		seen := 0
		_ = filepath.WalkDir(out, func(path string, entry os.DirEntry, err error) error {
			if err != nil || entry.IsDir() {
				return err
			}
			raw, _ := os.ReadFile(path)
			source := string(raw)
			for _, broken := range []string{"*/ BREAKOUT_A", `""" BREAKOUT_B`, "''' ", "‮", "\r"} {
				if strings.Contains(source, broken) && !strings.HasSuffix(path, ".md") {
					t.Errorf("%s: %s keeps %q", language, path, broken)
				}
			}
			if language == "elixir" || language == "ruby" {
				if strings.Contains(strings.ReplaceAll(source, `\#{BREAKOUT_D`, ""), "#{BREAKOUT_D") && language == "elixir" {
					t.Errorf("%s: %s interpolates the description", language, path)
				}
			}
			for _, line := range strings.Split(source, "\n") {
				if !strings.Contains(line, "BREAKOUT_C") {
					continue
				}
				seen++
				prefixes := lineComments[language]
				if prefixes == nil {
					continue
				}
				trimmed := strings.TrimSpace(line)
				ok := false
				for _, prefix := range prefixes {
					ok = ok || strings.HasPrefix(trimmed, prefix)
				}
				if !ok {
					t.Errorf("%s: %s has a description line that is not a comment: %q", language, path, line)
				}
			}
			return nil
		})
		if seen == 0 && language != "elixir" {
			t.Errorf("%s: the test description reached no file, so the test checks nothing", language)
		}
	}
}

// What becomes an identifier, a path or a literal is checked when the
// contract is read; anything outside the alphabet stops generation.
func TestHostileIdentifiersAndValuesStopGeneration(t *testing.T) {
	cases := map[string]func(doc map[string]any){
		"an enum value with a quote": func(doc map[string]any) {
			status := dig(doc, "components", "schemas", "Camera", "properties", "protocol")
			status["enum"] = []any{"rtsp", `archived"; evil(); "`}
		},
		"an enum value with a new line": func(doc map[string]any) {
			status := dig(doc, "components", "schemas", "Camera", "properties", "protocol")
			status["enum"] = []any{"rtsp\nevil"}
		},
		"a field that is not an identifier": func(doc map[string]any) {
			properties := dig(doc, "components", "schemas", "Camera", "properties")
			properties[`x"]; evil(); ["`] = map[string]any{"type": "string"}
		},
		"a model that is not an identifier": func(doc map[string]any) {
			schemas := dig(doc, "components", "schemas")
			schemas["Evil; drop"] = map[string]any{"type": "object", "properties": map[string]any{"id": map[string]any{"type": "string"}}}
			dig(schemas, "Camera", "properties")["evil"] = map[string]any{"$ref": "#/components/schemas/Evil; drop"}
		},
		"a path with a quote": func(doc map[string]any) {
			paths := dig(doc, "paths")
			paths[`/api/v1/cam"eras`] = paths["/api/v1/cameras"]
		},
		"a path parameter that is not an identifier": func(doc map[string]any) {
			paths := dig(doc, "paths")
			paths["/api/v1/detections/{id}/{a b}"] = paths["/api/v1/detections/{id}/image"]
		},
		"a server address with a quote": func(doc map[string]any) {
			doc["servers"] = []any{map[string]any{"url": `https://alpr.sh"; evil(); "`}}
		},
		"a contract version with a new line": func(doc map[string]any) {
			dig(doc, "info")["version"] = "1.0\nevil"
		},
		"a webhook type with a quote": func(doc map[string]any) {
			webhooks := dig(doc, "webhooks")
			webhooks[`recognition."created`] = webhooks["recognition.created"]
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := load(t, mutate); err == nil {
				t.Fatal("generation went ahead")
			}
		})
	}
}

// Each language's quoting writes one literal that reads back as the text.
func TestQuotingEscapesWhatEachLanguageReads(t *testing.T) {
	text := "a\"b'c\\d$e#{f}#$g\n\x01é"
	want := map[string]string{
		"go":         `"a\"b'c\\d$e#{f}#$g\n\x01é"`,
		"typescript": `"a\"b'c\\d$e#{f}#$g\n\u0001é"`,
		"python":     `"a\"b'c\\d$e#{f}#$g\n\x01é"`,
		"ruby":       `"a\"b'c\\d$e\#{f}\#$g\n\x01é"`,
		"elixir":     `"a\"b'c\\d$e\#{f}#$g\n\x01é"`,
		"php":        "'a\"b\\'c\\\\d$e#{f}#$g\n\x01é'",
		"java":       `"a\"b'c\\d$e#{f}#$g\n\001é"`,
		"csharp":     `"a\"b'c\\d$e#{f}#$g\n\u0001é"`,
		"rust":       `"a\"b'c\\d$e#{f}#$g\n\u{1}é"`,
		"swift":      `"a\"b'c\\d$e#{f}#$g\n\u{1}é"`,
		"dart":       `'a"b\'c\\d\$e#{f}#\$g\n\x01é'`,
	}
	for language, expected := range want {
		quote, ok := Languages[language].Funcs["quote"].(func(string) string)
		if !ok {
			t.Fatalf("%s has no quote function", language)
		}
		if got := quote(text); got != expected {
			t.Errorf("%s quoted %s, want %s", language, got, expected)
		}
	}
	for language, lang := range Languages {
		if lang.Funcs["quote"] == nil {
			t.Errorf("%s has no quote function", language)
		}
	}
}

func TestCleanTextBreaksWhatEndsAComment(t *testing.T) {
	got := cleanText("a */ b /* c \"\"\" d ''' e ]]> f\r\ng h\u0000‮")
	for _, bad := range []string{"*/", "/*", `"""`, "'''", "]]>", "\r", " ", "\x00", "‮"} {
		if strings.Contains(got, bad) {
			t.Errorf("%q still has %q", got, bad)
		}
	}
	if !strings.Contains(got, "f\ng\nh") {
		t.Errorf("line breaks lost: %q", got)
	}
	if line := cleanLine("one\ntwo\n\nthree"); line != "one two three" {
		t.Errorf("a summary is %q", line)
	}
}
