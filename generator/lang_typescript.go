package generator

import (
	"strings"
	"text/template"
)

func init() {
	register(Language{Name: "typescript", Funcs: template.FuncMap{
		// quote writes a string literal, escaped the way typescript reads it.
		"quote":  tsQuote,
		"tsType": tsType,
		// tsDoc writes a description as a JSDoc comment, or nothing.
		"tsDoc": func(indent, text string) string {
			text = strings.TrimSpace(text)
			if text == "" {
				return ""
			}
			return indent + "/** " + strings.ReplaceAll(text, "\n", "\n"+indent+" * ") + " */\n"
		},
	}})
}

// tsType is a field's TypeScript type; a string with allowed values is the
// union of them.
func tsType(t *TypeRef) string {
	switch t.Kind {
	case "string":
		if len(t.Enum) > 0 {
			values := make([]string, len(t.Enum))
			for i, value := range t.Enum {
				values[i] = tsQuote(value)
			}
			return strings.Join(values, " | ")
		}
		return "string"
	case "integer", "number":
		return "number"
	case "boolean":
		return "boolean"
	case "binary":
		// A photo: the bytes, or a Blob (a File too).
		return "Photo"
	case "model":
		return t.Model
	case "array":
		inner := tsType(t.Items)
		if strings.Contains(inner, "|") {
			inner = "(" + inner + ")"
		}
		return inner + "[]"
	case "map":
		return "Record<string, " + tsType(t.Items) + ">"
	case "any":
		return "unknown"
	}
	return "unknown"
}
