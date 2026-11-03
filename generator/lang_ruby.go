package generator

import (
	"strings"
	"text/template"
)

// rbReserved are names a Ruby keyword argument or reader cannot take: the
// language's keywords, and the methods every object answers that a reader
// would shadow.
var rbReserved = map[string]bool{
	"alias": true, "and": true, "begin": true, "break": true, "case": true, "class": true, "def": true, "defined?": true,
	"do": true, "else": true, "elsif": true, "end": true, "ensure": true, "false": true, "for": true, "if": true, "in": true,
	"module": true, "next": true, "nil": true, "not": true, "or": true, "redo": true, "rescue": true, "retry": true,
	"return": true, "self": true, "super": true, "then": true, "true": true, "undef": true, "unless": true, "until": true,
	"when": true, "while": true, "yield": true, "hash": true, "send": true, "object_id": true, "freeze": true,
	"to_h": true, "to_s": true, "inspect": true, "initialize": true, "dup": true, "clone": true,
}

func init() {
	register(Language{Name: "ruby", Funcs: template.FuncMap{
		// quote writes a string literal, escaped the way ruby reads it.
		"quote":   rubyQuote,
		"rbName":  rbName,
		"rbType":  rbType,
		"rbRead":  rbRead,
		"rbWrite": rbWrite,
		// rbBuild builds expr into t, or takes it as it is.
		"rbBuild": func(t *TypeRef, expr string) string {
			if convert := rbConvert(t, expr, 0); convert != "" {
				return convert
			}
			return expr
		},
		// rbDoc writes a description as comment lines over a declaration, or
		// nothing.
		"rbDoc": func(indent, text string) string {
			text = strings.TrimSpace(text)
			if text == "" {
				return ""
			}
			return indent + "# " + strings.ReplaceAll(text, "\n", "\n"+indent+"# ") + "\n"
		},
	}})
}

// rbName is a wire name as a Ruby reader and keyword argument.
func rbName(name string) string {
	name = strings.ReplaceAll(name, "-", "_")
	if rbReserved[name] {
		return name + "_"
	}
	return name
}

// rbType is a field's type as YARD writes it; a string with allowed values
// says them.
func rbType(t *TypeRef) string {
	switch t.Kind {
	case "string":
		if len(t.Enum) > 0 {
			values := make([]string, len(t.Enum))
			for i, value := range t.Enum {
				values[i] = `"` + value + `"`
			}
			return "String (" + strings.Join(values, ", ") + ")"
		}
		return "String"
	case "integer":
		return "Integer"
	case "number":
		return "Float"
	case "boolean":
		return "Boolean"
	case "model":
		return t.Model
	case "array":
		return "Array<" + rbType(t.Items) + ">"
	case "map":
		return "Hash{String => " + rbType(t.Items) + "}"
	case "any":
		return "Object"
	}
	return "Object"
}

// rbRead is the expression that reads a field out of the API's hash into its
// type: a nested model is built, anything else is taken as it is. A field the
// API always sends is fetched, so a missing one fails loudly.
func rbRead(f *Field) string {
	if f.Required && !f.Nullable {
		if convert := rbConvert(f.Type, `data.fetch("`+f.Wire+`")`, 0); convert != "" {
			return convert
		}
		return `data.fetch("` + f.Wire + `")`
	}
	if convert := rbConvert(f.Type, "value", 0); convert != "" {
		return `data["` + f.Wire + `"]&.then { |value| ` + convert + " }"
	}
	return `data["` + f.Wire + `"]`
}

// rbConvert builds expr into t, or is empty when nothing is to be built.
func rbConvert(t *TypeRef, expr string, depth int) string {
	each := "item" + strings.Repeat("_", depth)
	switch t.Kind {
	case "model":
		return t.Model + ".from_hash(" + expr + ")"
	case "array":
		if inner := rbConvert(t.Items, each, depth+1); inner != "" {
			return expr + ".map { |" + each + "| " + inner + " }"
		}
	case "map":
		if inner := rbConvert(t.Items, each, depth+1); inner != "" {
			return expr + ".transform_values { |" + each + "| " + inner + " }"
		}
	}
	return ""
}

// rbWrite is the expression that writes a param's value as JSON reads it: a
// nested model or list of them goes through Alpr.wire, a scalar as it is.
func rbWrite(f *Field) string {
	value := "@" + rbName(f.Wire)
	switch f.Type.Kind {
	case "model", "array", "map":
		return "Alpr.wire(" + value + ")"
	}
	return value
}
