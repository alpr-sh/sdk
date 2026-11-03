package generator

import (
	"strconv"
	"strings"
	"text/template"
)

// pyKeywords are names a Python parameter cannot take.
var pyKeywords = map[string]bool{"and": true, "as": true, "assert": true, "async": true, "await": true, "break": true, "class": true, "continue": true,
	"def": true, "del": true, "elif": true, "else": true, "except": true, "finally": true, "for": true, "from": true, "global": true, "if": true,
	"import": true, "in": true, "is": true, "lambda": true, "nonlocal": true, "not": true, "or": true, "pass": true, "raise": true, "return": true,
	"try": true, "while": true, "with": true, "yield": true}

func init() {
	register(Language{Name: "python", Funcs: template.FuncMap{
		// quote writes a string literal, escaped the way python reads it.
		"quote":  pythonQuote,
		"pyType": pyType,
		// pyText escapes text for a docstring: a backslash starts an escape
		// there, and a quote could end it.
		"pyText": pyText,
		"pyRead": pyRead,
		// pyBuild builds expr into t, or takes it as it is.
		"pyBuild": func(t *TypeRef, expr string) string {
			if convert := pyConvert(t, expr); convert != "" {
				return convert
			}
			return expr
		},
		"pyName": pyName,
		// pyField is a wire name as a Python attribute or parameter:
		// detectionId is detection_id.
		"pyField": func(wire string) string { return pyName(strings.ToLower(strings.Join(words(wire), "_"))) },
		// pyDoc writes a description as the docstring line under a field, or
		// nothing.
		"pyDoc": func(indent, text string) string {
			text = strings.TrimSpace(text)
			if text == "" {
				return ""
			}
			return "\n" + indent + `"""` + pyText(text) + `"""`
		},
	}})
}

func pyName(name string) string {
	name = strings.ReplaceAll(name, "-", "_")
	if pyKeywords[name] {
		return name + "_"
	}
	return name
}

// pyType is a field's Python annotation; a string with allowed values is
// their Literal.
func pyType(t *TypeRef) string {
	switch t.Kind {
	case "string":
		if len(t.Enum) > 0 {
			values := make([]string, len(t.Enum))
			for i, value := range t.Enum {
				values[i] = pythonQuote(value)
			}
			return "Literal[" + strings.Join(values, ", ") + "]"
		}
		return "str"
	case "integer":
		return "int"
	case "number":
		return "float"
	case "boolean":
		return "bool"
	case "model":
		return t.Model
	case "array":
		return "list[" + pyType(t.Items) + "]"
	case "map":
		return "dict[str, " + pyType(t.Items) + "]"
	case "binary":
		return "bytes"
	case "any":
		return "Any"
	}
	return "Any"
}

// pyRead is the expression that reads a field out of the API's dict into
// its type: a nested model is built, anything else is taken as it is. A field
// the API always sends is indexed, so a missing one fails loudly.
func pyRead(f *Field) string {
	if f.Required && !f.Nullable {
		if convert := pyConvert(f.Type, "data["+pythonQuote(f.Wire)+"]"); convert != "" {
			return convert
		}
		return `data["` + f.Wire + `"]`
	}
	if convert := pyConvert(f.Type, "data["+pythonQuote(f.Wire)+"]"); convert != "" {
		return "None if data.get(" + pythonQuote(f.Wire) + ") is None else " + convert
	}
	return "data.get(" + pythonQuote(f.Wire) + ")"
}

// pyConvert builds expr into t, or is empty when nothing is to be built. A
// number is read as a float, so a whole number the API writes without a point
// is still one.
func pyConvert(t *TypeRef, expr string) string { return pyConvertAt(t, expr, 0) }

func pyConvertAt(t *TypeRef, expr string, depth int) string {
	switch t.Kind {
	case "model":
		return t.Model + ".from_dict(" + expr + ")"
	case "number":
		return "float(" + expr + ")"
	case "array":
		name := "item" + strconv.Itoa(depth)
		if inner := pyConvertAt(t.Items, name, depth+1); inner != "" {
			return "[" + inner + " for " + name + " in " + expr + "]"
		}
	case "map":
		name := "value" + strconv.Itoa(depth)
		if inner := pyConvertAt(t.Items, name, depth+1); inner != "" {
			return "{key" + strconv.Itoa(depth) + ": " + inner + " for key" + strconv.Itoa(depth) + ", " + name + " in " + expr + ".items()}"
		}
	}
	return ""
}

func pyText(text string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(strings.TrimSpace(text))
}
