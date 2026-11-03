package generator

import (
	"sort"
	"strings"
	"text/template"
	"unicode"
)

// rustKeywords are names a Rust field, argument or method cannot take.
var rustKeywords = map[string]bool{
	"as": true, "async": true, "await": true, "break": true, "const": true, "continue": true, "crate": true,
	"dyn": true, "else": true, "enum": true, "extern": true, "false": true, "fn": true, "for": true, "gen": true,
	"if": true, "impl": true, "in": true, "let": true, "loop": true, "match": true, "mod": true, "move": true,
	"mut": true, "pub": true, "ref": true, "return": true, "self": true, "static": true, "struct": true,
	"super": true, "trait": true, "true": true, "try": true, "type": true, "unsafe": true, "use": true,
	"where": true, "while": true, "yield": true, "abstract": true, "become": true, "box": true, "do": true,
	"final": true, "macro": true, "override": true, "priv": true, "typeof": true, "unsized": true, "virtual": true,
}

func init() {
	register(Language{Name: "rust", Funcs: template.FuncMap{
		// quote writes a string literal, escaped the way rust reads it.
		"quote":  rustQuote,
		"rsName": rsName,
		"rsType": rsType,
		"rsArg":  rsArg,
		"rsDoc":  rsDoc,
		// rsWebhookNames are the event types a group is named by, sorted.
		"rsWebhookNames": func(groups []*WebhookGroup) []string {
			names := make([]string, len(groups))
			for i, group := range groups {
				names[i] = group.Name + "WebhookEvent"
			}
			sort.Strings(names)
			return names
		},
		"rsPath":      rsPath,
		"rsPathOwned": rsPathOwned,
		"rsEnums":     enumTypes,
		"rsVariant":   func(value string) string { return upperWords(value) },
		"rsAttrs":     rsAttrs,
		"rsInto":      rsInto,
		"rsInit":      rsInit,
		"required":    requiredFields,
		"optional":    optionalFields,
	}})
}

// EnumType is a string field's allowed values as one type the SDK declares:
// RecognitionSource for Recognition.source.
type EnumType struct {
	Name        string
	Model       string
	Field       string
	Description string
	Values      []string
}

// enumTypes are the enumerated fields of every model, outputs and request
// bodies alike, each named after its model and field.
func enumTypes(models []*Model) []EnumType {
	var out []EnumType
	for _, model := range models {
		for _, field := range model.Fields {
			if enum := enumOf(field.Type); enum != nil {
				out = append(out, EnumType{Name: enumName(models, model, field), Model: model.Name, Field: field.Wire,
					Description: field.Description, Values: enum.Enum})
			}
		}
	}
	return out
}

// enumOf is the string type with allowed values a field holds, itself or in
// a list or map, or nil.
func enumOf(t *TypeRef) *TypeRef {
	switch {
	case t == nil:
		return nil
	case t.Kind == "string" && len(t.Enum) > 0:
		return t
	case t.Kind == "array" || t.Kind == "map":
		return enumOf(t.Items)
	}
	return nil
}

// enumName names a field's enumeration: the model and the field, and Kind
// after them when that is already a model's name.
func enumName(models []*Model, model *Model, field *Field) string {
	name := model.Name + upperWords(field.Wire)
	for _, other := range models {
		if other.Name == name {
			return name + "Kind"
		}
	}
	return name
}

// upperWords writes one_time, BRL or past-due as OneTime, Brl and PastDue:
// every word capitalized, the rest of it in lower case, as Rust and Swift
// name types and cases.
func upperWords(name string) string {
	words := strings.FieldsFunc(name, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	var b strings.Builder
	for _, word := range words {
		word = strings.ToLower(word)
		b.WriteString(strings.ToUpper(word[:1]) + word[1:])
	}
	out := b.String()
	if out == "" || unicode.IsDigit(rune(out[0])) {
		out = "V" + out
	}
	return out
}

// snakeCase writes detectionId, detection-id or detection_id as detection_id.
func snakeCase(name string) string {
	var b strings.Builder
	for i, r := range name {
		switch {
		case r == '-' || r == ' ' || r == '.':
			b.WriteByte('_')
		case unicode.IsUpper(r):
			if i > 0 && !strings.HasSuffix(b.String(), "_") {
				b.WriteByte('_')
			}
			b.WriteRune(unicode.ToLower(r))
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// rsName is a field, argument or method name: snake case, and a keyword with
// an underscore after it (type_).
func rsName(name string) string {
	name = snakeCase(name)
	if rustKeywords[name] {
		return name + "_"
	}
	return name
}

// rsBase is a type without the Option a missing or null value adds.
func rsBase(models []*Model, model *Model, field *Field, t *TypeRef) string {
	switch t.Kind {
	case "string":
		if len(t.Enum) > 0 {
			return enumName(models, model, field)
		}
		return "String"
	case "integer":
		return "i64"
	case "number":
		return "f64"
	case "boolean":
		return "bool"
	case "binary":
		return "Vec<u8>"
	case "model":
		return t.Model
	case "array":
		return "Vec<" + rsBase(models, model, field, t.Items) + ">"
	case "map":
		return "std::collections::HashMap<String, " + rsBase(models, model, field, t.Items) + ">"
	case "any":
		return "serde_json::Value"
	}
	return "serde_json::Value"
}

// rsType is a field's Rust type: an Option when the API may answer null or
// leave it out, or when a request may leave it out.
func rsType(models []*Model, model *Model, field *Field) string {
	base := rsBase(models, model, field, field.Type)
	if field.Nullable || !field.Required {
		return "Option<" + base + ">"
	}
	return base
}

// rsArg is a field as the argument of a request body's constructor or
// setter: text, enumerations and the photo take anything that converts into
// them.
func rsArg(models []*Model, model *Model, field *Field) string {
	base := rsBase(models, model, field, field.Type)
	if field.Type.Kind == "string" || field.Type.Kind == "binary" {
		base = "impl Into<" + base + ">"
	}
	if field.Nullable && field.Required {
		return "Option<" + base + ">"
	}
	return base
}

// rsInto is how a constructor or setter stores its argument.
func rsInto(field *Field, arg string) string {
	bytes := field.Type.Kind == "string" || field.Type.Kind == "binary"
	switch {
	case bytes && field.Nullable && field.Required:
		return arg + ".map(Into::into)"
	case bytes:
		return arg + ".into()"
	}
	return arg
}

// rsInit is a field in a constructor's struct literal: its argument stored
// as rsInto says, or None when the field is optional.
func rsInit(field *Field) string {
	name := rsName(field.Wire)
	if !field.Required {
		return name + ": None"
	}
	if value := rsInto(field, name); value != name {
		return name + ": " + value
	}
	return name
}

// rsAttrs is the serde attribute over a field: its wire name when the Rust
// name differs, and leaving it out when it is unset and optional.
func rsAttrs(field *Field) string {
	var parts []string
	if rsName(field.Wire) != field.Wire {
		parts = append(parts, "rename = "+rustQuote(field.Wire))
	}
	if !field.Required {
		parts = append(parts, `default, skip_serializing_if = "Option::is_none"`)
	}
	if len(parts) == 0 {
		return ""
	}
	return "    #[serde(" + strings.Join(parts, ", ") + ")]\n"
}

// rsDoc writes a description as a doc comment, or nothing.
func rsDoc(indent, text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return ""
	}
	return indent + "/// " + strings.ReplaceAll(text, "\n", "\n"+indent+"/// ") + "\n"
}

// rsPath is a method's path as a &str expression, its parameters escaped.
func rsPath(m *Method) string {
	if len(m.PathParams) == 0 {
		return rustQuote(m.Path)
	}
	return "&" + rsFormat(m)
}

// rsPathOwned is a method's path as a String, for an iterator to keep.
func rsPathOwned(m *Method) string {
	if len(m.PathParams) == 0 {
		return "String::from(" + rustQuote(m.Path) + ")"
	}
	return rsFormat(m)
}

func rsFormat(m *Method) string {
	var format strings.Builder
	var args []string
	for _, part := range pathParts(m.Path) {
		if part.Param != "" {
			format.WriteString("{}")
			args = append(args, "crate::client::escape("+rsName(part.Param)+")")
			continue
		}
		format.WriteString(strings.NewReplacer("{", "{{", "}", "}}").Replace(part.Literal))
	}
	return `format!("` + format.String() + `", ` + strings.Join(args, ", ") + ")"
}

func requiredFields(m *Model) []*Field {
	var out []*Field
	for _, field := range m.Fields {
		if field.Required {
			out = append(out, field)
		}
	}
	return out
}

func optionalFields(m *Model) []*Field {
	var out []*Field
	for _, field := range m.Fields {
		if !field.Required {
			out = append(out, field)
		}
	}
	return out
}
