package generator

import (
	"strings"
	"text/template"
)

func init() {
	register(Language{Name: "php", Funcs: template.FuncMap{
		// quote writes a string literal, escaped the way php reads it.
		"quote":    phpQuote,
		"phpType":  phpType,
		"phpDoc":   phpDoc,
		"phpRead":  phpRead,
		"phpShape": phpShape,
		"phpProp":  phpProp,
		"phpName":  phpName,
	}})
}

// phpType is a property's declared PHP type.
func phpType(f *Field) string {
	var base string
	switch f.Type.Kind {
	case "string":
		base = "string"
	case "integer":
		base = "int"
	case "number":
		base = "float"
	case "boolean":
		base = "bool"
	case "model":
		base = f.Type.Model
	case "array", "map":
		base = "array"
	case "any":
		base = "mixed"
	default:
		base = "mixed"
	}
	if (f.Nullable || !f.Required) && base != "mixed" {
		return "?" + base
	}
	return base
}

// phpDoc is a type as phpdoc and PHPStan read it: lists, maps and the
// allowed values of a string.
func phpDoc(t *TypeRef) string {
	switch t.Kind {
	case "string":
		if len(t.Enum) > 0 {
			values := make([]string, len(t.Enum))
			for i, value := range t.Enum {
				values[i] = "'" + value + "'"
			}
			return strings.Join(values, "|")
		}
		return "string"
	case "integer":
		return "int"
	case "number":
		return "float"
	case "boolean":
		return "bool"
	case "model":
		return t.Model
	case "array":
		return "list<" + phpDoc(t.Items) + ">"
	case "map":
		return "array<string, " + phpDoc(t.Items) + ">"
	}
	return "mixed"
}

// phpRead is the expression that reads a field out of the API's array: a
// nested model is built, anything else is taken as it is.
func phpRead(f *Field) string {
	value := "$data['" + f.Wire + "']"
	convert := phpConvert(f.Type, value)
	switch {
	case f.Required && !f.Nullable && convert != "":
		return convert
	case f.Required && !f.Nullable:
		return value
	case convert != "":
		return "isset(" + value + ") ? " + convert + " : null"
	}
	return value + " ?? null"
}

func phpConvert(t *TypeRef, expr string) string {
	switch t.Kind {
	case "model":
		return t.Model + "::fromArray(" + expr + ")"
	case "array":
		if inner := phpConvert(t.Items, "$item"); inner != "" {
			// array_map keeps the keys; a list is what the property says.
			return "array_values(array_map(static fn (array $item) => " + inner + ", " + expr + "))"
		}
	case "map":
		if inner := phpConvert(t.Items, "$item"); inner != "" {
			return "array_map(static fn (array $item) => " + inner + ", " + expr + ")"
		}
	}
	return ""
}

// phpShape is a request body as a PHPStan array shape.
func phpShape(m *Model) string {
	fields := make([]string, len(m.Fields))
	for i, f := range m.Fields {
		optional := ""
		if !f.Required {
			optional = "?"
		}
		typ := phpDoc(f.Type)
		if f.Nullable {
			typ += "|null"
		}
		fields[i] = f.Wire + optional + ": " + typ
	}
	return "array{" + strings.Join(fields, ", ") + "}"
}

// phpProp is the docblock over a promoted property: its description and,
// when the declared type says less, its phpdoc type.
func phpProp(f *Field) string {
	var lines []string
	if text := strings.TrimSpace(f.Description); text != "" {
		lines = append(lines, text)
	}
	if f.Type.Kind == "array" || f.Type.Kind == "map" || len(f.Type.Enum) > 0 {
		typ := phpDoc(f.Type)
		if f.Nullable || !f.Required {
			typ += "|null"
		}
		lines = append(lines, "@var "+typ)
	}
	const indent = "        "
	switch len(lines) {
	case 0:
		return ""
	case 1:
		return indent + "/** " + lines[0] + " */\n"
	}
	return indent + "/**\n" + indent + " * " + strings.Join(lines, "\n"+indent+" * ") + "\n" + indent + " */\n"
}

// phpName writes customer_id as customerId: PHP's camel case keeps an
// acronym in lower case, as PSR-12 code does.
func phpName(wire string) string {
	parts := strings.FieldsFunc(wire, func(r rune) bool { return r == '_' || r == '-' })
	for i, part := range parts {
		if i > 0 {
			parts[i] = strings.ToUpper(part[:1]) + part[1:]
		}
	}
	return strings.Join(parts, "")
}
