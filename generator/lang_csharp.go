package generator

import (
	"fmt"
	"sort"
	"strings"
	"text/template"
)

// csKeywords are names a C# parameter cannot take without an @.
var csKeywords = map[string]bool{
	"abstract": true, "as": true, "base": true, "bool": true, "break": true, "byte": true, "case": true,
	"catch": true, "char": true, "checked": true, "class": true, "const": true, "continue": true,
	"decimal": true, "default": true, "delegate": true, "do": true, "double": true, "else": true,
	"enum": true, "event": true, "explicit": true, "extern": true, "false": true, "finally": true,
	"fixed": true, "float": true, "for": true, "foreach": true, "goto": true, "if": true, "implicit": true,
	"in": true, "int": true, "interface": true, "internal": true, "is": true, "lock": true, "long": true,
	"namespace": true, "new": true, "null": true, "object": true, "operator": true, "out": true,
	"override": true, "params": true, "private": true, "protected": true, "public": true,
	"readonly": true, "ref": true, "return": true, "sbyte": true, "sealed": true, "short": true,
	"sizeof": true, "stackalloc": true, "static": true, "string": true, "struct": true, "switch": true,
	"this": true, "throw": true, "true": true, "try": true, "typeof": true, "uint": true, "ulong": true,
	"unchecked": true, "unsafe": true, "ushort": true, "using": true, "virtual": true, "void": true,
	"volatile": true, "while": true,
}

func init() {
	register(Language{Name: "csharp", Funcs: template.FuncMap{
		// quote writes a string literal, escaped the way csharp reads it.
		"quote":  csharpQuote,
		"csName": idiomPascal,
		// csProp is a field's property name; a property cannot take its
		// class's name.
		"csProp": func(model, wire string) string {
			name := idiomPascal(wire)
			if name == model {
				return name + "Value"
			}
			return name
		},
		"csParam": func(wire string) string {
			name := idiomCamel(wire)
			if csKeywords[name] {
				return "@" + name
			}
			return name
		},
		"csType":      csType,
		"csRequired":  func(f *Field, input bool) bool { return f.Required && (input || !f.Nullable) },
		"csConst":     func(field, value string) string { return idiomPascal(field) + csConstPart(value) },
		"csDoc":       csDoc,
		"csText":      csText,
		"csEnvelopes": csEnvelopes,
		"csWrite":     csWrite,
		"csRef":       csRef,
		// csTypeInfo is the JsonTypeInfo property the JSON context names a
		// webhook's data by: Order, DictionaryStringString.
		"csTypeInfo": func(t *TypeRef) (string, error) {
			switch {
			case t.Kind == "model":
				return t.Model, nil
			case t.Kind == "map" && t.Items.Kind == "string":
				return "DictionaryStringString", nil
			}
			return "", fmt.Errorf("generator: csharp: a webhook carrying %s is not supported", t.Kind)
		},
	}})
}

// csConstPart writes one_time as OneTime and BRL as BRL.
func csConstPart(value string) string {
	var b strings.Builder
	upper := true
	for _, r := range value {
		switch {
		case r >= 'a' && r <= 'z':
			if upper {
				r -= 'a' - 'A'
			}
			b.WriteRune(r)
			upper = false
		case r >= 'A' && r <= 'Z' || r >= '0' && r <= '9':
			b.WriteRune(r)
			upper = false
		default:
			upper = true
		}
	}
	out := b.String()
	if out == "" || out[0] >= '0' && out[0] <= '9' {
		out = "_" + out
	}
	return out
}

// csType is a field's C# type: nullable when the API may leave it out or
// send null, or a request may leave it out.
func csType(f *Field, input bool) string {
	base := csRef(f.Type)
	if f.Required && (input || !f.Nullable) {
		return base
	}
	return base + "?"
}

func csRef(t *TypeRef) string {
	switch t.Kind {
	case "string":
		return "string"
	case "integer":
		return "long"
	case "number":
		return "double"
	case "boolean":
		return "bool"
	case "model":
		return t.Model
	case "array":
		return "IReadOnlyList<" + csRef(t.Items) + ">"
	case "map":
		return "IReadOnlyDictionary<string, " + csRef(t.Items) + ">"
	case "any":
		return "JsonElement"
	}
	return "JsonElement"
}

// csWrite checks a request field can be written: the request bodies are
// scalars, lists and maps of them, and the source-generated JSON context
// lists none of the models as a body.
func csWrite(f *Field) (string, error) {
	if inputHoldsModel(f.Type) {
		return "", fmt.Errorf("generator: csharp: a request body holding the model %s is not supported", f.Type.Model)
	}
	return "", nil
}

// csText escapes a description for an XML doc comment, on one line.
func csText(text string) string {
	return strings.Join(strings.Fields(xmlText(text)), " ")
}

// xmlText escapes text for an XML doc comment, keeping its lines.
func xmlText(text string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(strings.TrimSpace(text))
}

// csDoc writes a description as an XML doc summary.
func csDoc(indent, text string) string {
	text = xmlText(text)
	return indent + "/// <summary>" + strings.ReplaceAll(text, "\n", "\n"+indent+"/// ") + "</summary>\n"
}

// Envelope is one type the API answers in its data envelope, for the
// source-generated JSON context.
type Envelope struct {
	// Type is the C# type in the envelope: Product, Page<Product>.
	Type string
	// Name is its JsonTypeInfo's name on the context.
	Name string
}

// csEnvelopes are the types the services read, once each.
func csEnvelopes(services []*Service) []Envelope {
	seen := map[string]Envelope{}
	for _, service := range services {
		for _, method := range service.Methods {
			if method.Paginated {
				seen[method.Item+"Page"] = Envelope{Type: "Page<" + method.Item + ">", Name: method.Item + "PageEnvelope"}
			} else if !method.NoContent {
				seen[method.Response] = Envelope{Type: method.Response, Name: method.Response + "Envelope"}
			}
		}
	}
	out := make([]Envelope, 0, len(seen))
	for _, envelope := range seen {
		out = append(out, envelope)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}
