package generator

import (
	"strings"
	"text/template"
)

// swiftKeywords are names a Swift property, argument or case must write in
// backticks.
var swiftKeywords = map[string]bool{
	"associatedtype": true, "class": true, "deinit": true, "enum": true, "extension": true, "fileprivate": true,
	"func": true, "import": true, "init": true, "inout": true, "internal": true, "let": true, "open": true,
	"operator": true, "private": true, "precedencegroup": true, "protocol": true, "public": true, "rethrows": true,
	"static": true, "struct": true, "subscript": true, "typealias": true, "var": true, "break": true, "case": true,
	"catch": true, "continue": true, "default": true, "defer": true, "do": true, "else": true, "fallthrough": true,
	"for": true, "guard": true, "if": true, "in": true, "repeat": true, "return": true, "throw": true,
	"switch": true, "where": true, "while": true, "as": true, "await": true, "false": true, "is": true, "nil": true,
	"self": true, "super": true, "throws": true, "true": true, "try": true, "Any": true, "Self": true,
}

func init() {
	register(Language{Name: "swift", Funcs: template.FuncMap{
		// quote writes a string literal, escaped the way swift reads it.
		"quote":     swiftQuote,
		"swName":    swName,
		"swType":    swType,
		"swDoc":     swDoc,
		"swPath":    swPath,
		"swEnums":   enumTypes,
		"swCase":    swCase,
		"swKey":     swKey,
		"swParams":  swParams,
		"required":  requiredFields,
		"optional":  optionalFields,
		"swLiteral": swLiteral,
		// swText is the Swift expression that writes a multipart text field's
		// value from expr, a non-optional value of type t.
		"swText": swText,
		// swLower writes BenefitGrant as benefitGrant, an enumeration case.
		"swLower": func(name string) string { return swIdent(strings.ToLower(name[:1]) + name[1:]) },
	}})
}

// swIdent is a lower camel case name as Swift writes it, in backticks when it
// is a keyword.
func swIdent(name string) string {
	if swiftKeywords[name] {
		return "`" + name + "`"
	}
	return name
}

// swName is a property or argument: customer_id as customerID, cancel_url as
// cancelURL, as Swift's guidelines keep an acronym in one case.
func swName(wire string) string {
	return swIdent(Camel(snakeCase(wire)))
}

// swCase is an enumeration's value as a static member: one_time as oneTime,
// BRL as brl.
func swCase(value string) string {
	upper := upperWords(value)
	return swIdent(strings.ToLower(upper[:1]) + upper[1:])
}

// swKey is a CodingKeys case: the property, and its wire name when they
// differ.
func swKey(field *Field) string {
	name := swName(field.Wire)
	if strings.Trim(name, "`") == field.Wire {
		return name
	}
	return name + " = " + swLiteral(field.Wire)
}

// swLiteral is a Swift string literal.
func swLiteral(s string) string {
	return swiftQuote(s)
}

func swBase(models []*Model, model *Model, field *Field, t *TypeRef) string {
	switch t.Kind {
	case "string":
		if len(t.Enum) > 0 {
			return enumName(models, model, field)
		}
		return "String"
	case "integer":
		return "Int"
	case "number":
		return "Double"
	case "boolean":
		return "Bool"
	case "model":
		return t.Model
	case "array":
		return "[" + swBase(models, model, field, t.Items) + "]"
	case "map":
		return "[String: " + swBase(models, model, field, t.Items) + "]"
	case "binary":
		return "Data"
	case "any":
		return "JSONValue"
	}
	return "String"
}

// swText is the Swift expression that turns expr, of type t, into the text of
// a multipart field.
func swText(t *TypeRef, expr string) string {
	switch t.Kind {
	case "integer":
		return "String(" + expr + ")"
	case "number":
		return "formatNumber(" + expr + ")"
	case "boolean":
		return "(" + expr + " ? \"true\" : \"false\")"
	case "string":
		if len(t.Enum) > 0 {
			return expr + ".rawValue"
		}
	}
	return expr
}

// swType is a field's Swift type: optional when the API may answer null or
// leave it out, or when a request may leave it out.
func swType(models []*Model, model *Model, field *Field) string {
	base := swBase(models, model, field, field.Type)
	if field.Nullable || !field.Required {
		return base + "?"
	}
	return base
}

// swParams are a model's memberwise initializer parameters: the required
// fields, then the optional ones defaulting to nil.
func swParams(models []*Model, model *Model) string {
	var params []string
	for _, field := range requiredFields(model) {
		params = append(params, swName(field.Wire)+": "+swType(models, model, field))
	}
	for _, field := range optionalFields(model) {
		params = append(params, swName(field.Wire)+": "+swType(models, model, field)+" = nil")
	}
	return strings.Join(params, ", ")
}

// swDoc writes a description as a doc comment, or nothing.
func swDoc(indent, text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return ""
	}
	return indent + "/// " + strings.ReplaceAll(text, "\n", "\n"+indent+"/// ") + "\n"
}

// swPath is a method's path as a string literal, its parameters escaped.
func swPath(m *Method) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, part := range pathParts(m.Path) {
		if part.Param != "" {
			b.WriteString(`\(escape(` + swName(part.Param) + `))`)
			continue
		}
		b.WriteString(inner(swiftQuote(part.Literal)))
	}
	b.WriteByte('"')
	return b.String()
}
