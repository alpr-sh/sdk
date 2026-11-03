package generator

import (
	"fmt"
	"strings"
	"text/template"
)

// javaKeywords are names a Java parameter or field cannot take.
var javaKeywords = map[string]bool{
	"abstract": true, "assert": true, "boolean": true, "break": true, "byte": true, "case": true, "catch": true,
	"char": true, "class": true, "const": true, "continue": true, "default": true, "do": true, "double": true,
	"else": true, "enum": true, "extends": true, "final": true, "finally": true, "float": true, "for": true,
	"goto": true, "if": true, "implements": true, "import": true, "instanceof": true, "int": true,
	"interface": true, "long": true, "native": true, "new": true, "package": true, "private": true,
	"protected": true, "public": true, "return": true, "short": true, "static": true, "strictfp": true,
	"super": true, "switch": true, "synchronized": true, "this": true, "throw": true, "throws": true,
	"transient": true, "try": true, "void": true, "volatile": true, "while": true, "true": true,
	"false": true, "null": true, "var": true, "record": true, "yield": true,
}

func init() {
	register(Language{Name: "java", Funcs: template.FuncMap{
		// quote writes a string literal, escaped the way java reads it.
		"quote":      javaQuote,
		"javaPascal": idiomPascal,
		"javaName": func(wire string) string {
			name := idiomCamel(wire)
			if javaKeywords[name] {
				return name + "Value"
			}
			return name
		},
		"javaType":   javaType,
		"javaBoxed":  func(t *TypeRef) string { return javaRef(t, true) },
		"javaRead":   javaRead,
		"javaForm":   javaForm,
		"javaConst":  func(field, value string) string { return constName(field) + "_" + constName(value) },
		"javaDoc":    javaDoc,
		"javaText":   javaText,
		"javaGetter": javaGetter,
		// javaConvertCall turns the decoded JSON value in expr into t.
		"javaConvertCall": func(t *TypeRef, expr string) string {
			if t.Kind == "model" {
				return t.Model + ".fromJson(" + expr + ")"
			}
			return javaConvert(t) + ".apply(" + expr + ")"
		},
	}})
}

// idiomPascal writes customer_id as CustomerId: Java and .NET keep an
// acronym in title case, as their style guides ask.
func idiomPascal(wire string) string {
	parts := strings.FieldsFunc(wire, func(r rune) bool { return r == '_' || r == '-' || r == '.' || r == ' ' })
	for i, part := range parts {
		parts[i] = strings.ToUpper(part[:1]) + part[1:]
	}
	return strings.Join(parts, "")
}

// idiomCamel writes customer_id as customerId.
func idiomCamel(wire string) string {
	pascal := idiomPascal(wire)
	if pascal == "" {
		return pascal
	}
	return strings.ToLower(pascal[:1]) + pascal[1:]
}

// constName writes partially_refunded as PARTIALLY_REFUNDED, anything that
// is not a letter or a digit becoming an underscore.
func constName(value string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(value) {
		if r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
		} else {
			b.WriteRune('_')
		}
	}
	out := b.String()
	if out == "" || out[0] >= '0' && out[0] <= '9' {
		out = "_" + out
	}
	return out
}

// javaType is a field's declared Java type: a primitive when the API always
// sends the field (or a request must), a boxed type that may be null
// otherwise.
func javaType(f *Field, input bool) string {
	present := f.Required && (input || !f.Nullable)
	return javaRef(f.Type, !present)
}

func javaRef(t *TypeRef, boxed bool) string {
	switch t.Kind {
	case "string":
		return "String"
	case "integer":
		if boxed {
			return "Long"
		}
		return "long"
	case "number":
		if boxed {
			return "Double"
		}
		return "double"
	case "boolean":
		if boxed {
			return "Boolean"
		}
		return "boolean"
	case "model":
		return t.Model
	case "array":
		return "List<" + javaRef(t.Items, true) + ">"
	case "map":
		return "Map<String, " + javaRef(t.Items, true) + ">"
	case "binary":
		return "byte[]"
	case "any":
		return "Object"
	}
	return "Object"
}

// javaGetter is the accessor of a field: getCreatedAt.
func javaGetter(wire string) string { return "get" + idiomPascal(wire) }

// javaConvert is the function that turns a decoded JSON value into t.
func javaConvert(t *TypeRef) string {
	switch t.Kind {
	case "string":
		return "Json::asString"
	case "integer":
		return "Json::asLong"
	case "number":
		return "Json::asDouble"
	case "boolean":
		return "Json::asBoolean"
	case "model":
		return "Json.model(" + t.Model + "::fromJson)"
	case "array":
		return "Json.list(" + javaConvert(t.Items) + ")"
	case "map":
		return "Json.map(" + javaConvert(t.Items) + ")"
	case "any":
		return "Json::any"
	}
	return "Json::any"
}

// javaRead reads a field out of the API's object. A field the API always
// sends is required, so a missing one fails loudly.
func javaRead(f *Field) string {
	if f.Required && !f.Nullable {
		return `Json.required(data, "` + f.Wire + `", ` + javaConvert(f.Type) + ")"
	}
	return `Json.optional(data, "` + f.Wire + `", ` + javaConvert(f.Type) + ")"
}

// javaForm is the Java expression that writes the value of a multipart text
// field held in expr. A request field is a scalar; a list, a map or a nested
// model stops the generator rather than writing a body Java cannot encode.
func javaForm(t *TypeRef, expr string) (string, error) {
	switch t.Kind {
	case "string":
		return expr, nil
	case "integer":
		return "Long.toString(" + expr + ")", nil
	case "number":
		return "Multipart.number(" + expr + ")", nil
	case "boolean":
		return "Boolean.toString(" + expr + ")", nil
	}
	return "", fmt.Errorf("generator: java: a multipart field of kind %s is not supported", t.Kind)
}

func inputHoldsModel(t *TypeRef) bool {
	if t.Kind == "model" {
		return true
	}
	return t.Items != nil && inputHoldsModel(t.Items)
}

// javaDoc writes a description as a Javadoc comment, or nothing. HTML is
// escaped so doclint reads it as text.
func javaDoc(indent, text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return ""
	}
	return indent + "/** " + strings.ReplaceAll(javaText(text), "\n", "\n"+indent+" * ") + " */\n"
}

// javaText escapes a description for Javadoc.
func javaText(text string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "*/", "*&#47;", "@", "&#64;", `\`, "&#92;").Replace(strings.TrimSpace(text))
}
