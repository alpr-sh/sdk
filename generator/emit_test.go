package generator

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Every language writes its SDK, a file a model or a service written once
// for each, and nothing it did not write is left behind.
func TestEveryLanguageWritesItsSDK(t *testing.T) {
	ir, err := Load("../openapi.json", "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	expected := map[string][]string{
		"go":         {"go.mod", "client.go", "services.go", "models.go", "webhooks.go"},
		"typescript": {"package.json", "src/client.ts", "src/services.ts", "src/webhooks.ts", "test/alpr.test.ts"},
		"python":     {"pyproject.toml", "src/alpr/__init__.py", "src/alpr/py.typed", "src/alpr/webhooks.py", "tests/test_alpr.py"},
		"php":        {"composer.json", "src/Alpr.php", "src/Models/Product.php", "src/Services/ProductsService.php", "src/OrderWebhookEvent.php", "src/Webhook.php"},
		"ruby":       {"alpr-sdk.gemspec", "lib/alpr.rb", "lib/alpr/services.rb", "lib/alpr/webhooks.rb", "test/alpr_test.rb"},
		"elixir":     {"mix.exs", "lib/alpr.ex", "lib/alpr/services.ex", "lib/alpr/webhook.ex", "test/alpr_test.exs"},
		"java":       {"pom.xml", "src/main/java/sh/alpr/Alpr.java", "src/main/java/sh/alpr/Product.java", "src/main/java/sh/alpr/ProductsService.java", "src/main/java/sh/alpr/OrderWebhookEvent.java"},
		"csharp":     {"Alpr.slnx", "src/Alpr/AlprClient.cs", "src/Alpr/Models/Product.cs", "src/Alpr/Services/ProductsService.cs", "src/Alpr/WebhookEvents.cs"},
		"dart":       {"pubspec.yaml", "lib/alpr_sdk.dart", "lib/src/models.dart", "lib/src/webhooks.dart", "test/alpr_test.dart"},
		"rust":       {"Cargo.toml", "src/lib.rs", "src/models.rs", "src/webhooks.rs", "tests/alpr.rs"},
		"swift":      {"Package.swift", "Sources/Alpr/AlprClient.swift", "Sources/Alpr/Models.swift", "Sources/Alpr/Webhooks.swift", "Tests/AlprTests/AlprTests.swift"},
	}
	if len(expected) != len(Languages) {
		t.Fatalf("languages %d, checked %d", len(Languages), len(expected))
	}
	for language, files := range expected {
		out := t.TempDir()
		stale := filepath.Join(out, "stale.txt")
		if err := os.WriteFile(stale, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := Generate(ir, language, out); err != nil {
			t.Fatalf("%s: %v", language, err)
		}
		for _, file := range files {
			if _, err := os.Stat(filepath.Join(out, file)); err != nil {
				t.Errorf("%s did not write %s", language, file)
			}
		}
		if _, err := os.Stat(stale); err == nil {
			t.Errorf("%s left a file it does not write", language)
		}
		_ = filepath.WalkDir(out, func(path string, entry os.DirEntry, err error) error {
			if err == nil && (strings.Contains(path, "__") || strings.HasSuffix(path, ".tmpl")) && !strings.Contains(path, "__init__") {
				t.Errorf("%s wrote %s", language, path)
			}
			return err
		})
	}
}
