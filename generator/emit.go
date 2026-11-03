package generator

import (
	"bytes"
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"text/template"
)

//go:embed all:templates
var templates embed.FS

// Language is one SDK: where its templates are and the functions they use to
// name and type what the IR describes.
type Language struct {
	Name  string
	Funcs template.FuncMap
}

// Languages are the SDKs this generator writes.
var Languages = map[string]Language{}

func register(language Language) { Languages[language.Name] = language }

// Generate writes the SDK in language to out. Every file under
// templates/<language> is rendered with the IR -- a ".tmpl" suffix is
// dropped -- and the directory is cleared first, so the SDK is always
// exactly what the generator writes and nothing is edited by hand.
func Generate(ir *IR, language, out string) error {
	lang, ok := Languages[language]
	if !ok {
		return fmt.Errorf("generator: unknown language %q", language)
	}
	root := path.Join("templates", language)
	if _, err := fs.Stat(templates, root); err != nil {
		return fmt.Errorf("generator: no templates for %s", language)
	}
	if err := clear(out); err != nil {
		return err
	}
	funcs := commonFuncs()
	for name, fn := range lang.Funcs {
		funcs[name] = fn
	}
	return fs.WalkDir(templates, root, func(file string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		source, err := templates.ReadFile(file)
		if err != nil {
			return err
		}
		target := strings.TrimPrefix(file, root+"/")
		target = strings.ReplaceAll(target, "_dot_", ".")
		for _, scope := range scopes(ir, target) {
			if err := render(file, scope.target, source, scope.Scope, funcs, out); err != nil {
				return err
			}
		}
		return nil
	})
}

// Scope is what a template sees: the IR and, in a file written once per
// model, per service or per webhook group, the one it is about.
type Scope struct {
	*IR
	Model   *Model
	Service *Service
	Webhook *WebhookGroup
}

type scoped struct {
	Scope
	target string
}

// scopes are the files one template writes. A path naming __model__ is
// written once for each model the API answers, one naming __service__ once
// for each service, and one naming __webhook__ once for each webhook group,
// for the languages that keep one class a file.
func scopes(ir *IR, target string) []scoped {
	switch {
	case strings.Contains(target, "__model__"):
		var out []scoped
		for _, model := range ir.Models {
			if !model.Input {
				out = append(out, scoped{Scope{IR: ir, Model: model}, strings.ReplaceAll(target, "__model__", model.Name)})
			}
		}
		return out
	case strings.Contains(target, "__webhook__"):
		var out []scoped
		for _, group := range ir.Webhooks {
			out = append(out, scoped{Scope{IR: ir, Webhook: group}, strings.ReplaceAll(target, "__webhook__", group.Name)})
		}
		return out
	case strings.Contains(target, "__service__"):
		var out []scoped
		for _, service := range ir.Services {
			out = append(out, scoped{Scope{IR: ir, Service: service}, strings.ReplaceAll(target, "__service__", Pascal(service.Name))})
		}
		return out
	}
	return []scoped{{Scope{IR: ir}, target}}
}

func render(file, target string, source []byte, scope Scope, funcs template.FuncMap, out string) error {
	if strings.HasSuffix(target, ".tmpl") {
		target = strings.TrimSuffix(target, ".tmpl")
		tmpl, err := template.New(path.Base(file)).Funcs(funcs).Parse(string(source))
		if err != nil {
			return fmt.Errorf("generator: %s: %w", file, err)
		}
		var buf bytes.Buffer
		if err := tmpl.Execute(&buf, scope); err != nil {
			return fmt.Errorf("generator: %s: %w", file, err)
		}
		source = buf.Bytes()
	}
	if strings.HasSuffix(target, ".go") {
		formatted, err := FormatGo(source)
		if err != nil {
			return fmt.Errorf("generator: format %s: %w\n%s", target, err, source)
		}
		source = formatted
	}
	destination := filepath.Join(out, filepath.FromSlash(target))
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	return os.WriteFile(destination, source, 0o644)
}

// clear empties out, keeping what a package manager or a build put there
// that the generator does not own: the folders they create and the lock file
// a release installs from.
func clear(out string) error {
	entries, err := os.ReadDir(out)
	if os.IsNotExist(err) {
		return os.MkdirAll(out, 0o755)
	}
	if err != nil {
		return err
	}
	keep := map[string]bool{"node_modules": true, "vendor": true, ".venv": true, "dist": true, "__pycache__": true, ".pytest_cache": true,
		"target": true, "bin": true, "obj": true, "_build": true, "deps": true, ".dart_tool": true, ".build": true, "package-lock.json": true}
	for _, entry := range entries {
		if keep[entry.Name()] {
			continue
		}
		if err := os.RemoveAll(filepath.Join(out, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func commonFuncs() template.FuncMap {
	return template.FuncMap{
		"pascal": Pascal,
		"camel":  Camel,
		// snake writes detectionId and payment-methods as detection_id and payment_methods.
		"snake": func(name string) string { return strings.ToLower(strings.Join(words(name), "_")) },
		// lines continues a line comment over every line of text: prefix is
		// what each line after the first starts with.
		"lines": func(prefix, text string) string { return strings.ReplaceAll(text, "\n", "\n"+prefix) },
		"upper": strings.ToUpper,
		"lower": strings.ToLower,
		"join":  strings.Join,
		// singular writes a service as the noun of one of its resources.
		"singular": func(name string) string {
			if strings.HasSuffix(name, "ies") {
				return strings.TrimSuffix(name, "ies") + "y"
			}
			return strings.TrimSuffix(name, "s")
		},
		"sortedEnums": sortedEnums,
		// outputs are the models the API answers; inputs, the request bodies.
		"outputs": func(models []*Model) []*Model { return pick(models, false) },
		"inputs":  func(models []*Model) []*Model { return pick(models, true) },
		"hasPath": func(m *Method) bool { return len(m.PathParams) > 0 },
		// pathTemplate splits a path into its literal parts and parameters.
		"pathParts":     pathParts,
		"webhookModels": webhookModels,
		// article writes a noun with a or an before it: an Order.
		"article": func(noun string) string {
			if noun != "" && strings.ContainsRune("AEIOUaeiou", rune(noun[0])) {
				return "an " + noun
			}
			return "a " + noun
		},
	}
}

// webhookModels are the models the webhooks carry, sorted, once each.
func webhookModels(groups []*WebhookGroup) []string {
	seen := map[string]bool{}
	var out []string
	for _, group := range groups {
		if !seen[group.Model] {
			seen[group.Model] = true
			out = append(out, group.Model)
		}
	}
	sort.Strings(out)
	return out
}

func pick(models []*Model, input bool) []*Model {
	var out []*Model
	for _, model := range models {
		if model.Input == input {
			out = append(out, model)
		}
	}
	return out
}

// EnumValue is one allowed value of a model's field, for the constants an
// SDK declares.
type EnumValue struct {
	Model, Field, Value string
}

// sortedEnums are every model field's allowed values.
func sortedEnums(models []*Model) []EnumValue {
	var out []EnumValue
	for _, model := range models {
		if model.Input {
			continue
		}
		for _, field := range model.Fields {
			if field.Type.Kind != "string" {
				continue
			}
			for _, value := range field.Type.Enum {
				out = append(out, EnumValue{Model: model.Name, Field: field.Wire, Value: value})
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Model != out[j].Model {
			return out[i].Model < out[j].Model
		}
		return out[i].Field < out[j].Field
	})
	return out
}

// PathPart is a literal piece of a path or the name of a parameter.
type PathPart struct {
	Literal string
	Param   string
}

func pathParts(p string) []PathPart {
	var parts []PathPart
	for p != "" {
		open := strings.Index(p, "{")
		if open < 0 {
			parts = append(parts, PathPart{Literal: p})
			break
		}
		if open > 0 {
			parts = append(parts, PathPart{Literal: p[:open]})
		}
		end := strings.Index(p, "}")
		parts = append(parts, PathPart{Param: p[open+1 : end]})
		p = p[end+1:]
	}
	return parts
}
