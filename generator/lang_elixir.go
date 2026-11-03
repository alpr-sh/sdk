package generator

import (
	"strings"
	"text/template"
	"unicode/utf8"
)

// exReserved are names an Elixir variable cannot take.
var exReserved = map[string]bool{
	"do": true, "end": true, "fn": true, "when": true, "and": true, "or": true, "not": true, "in": true,
	"true": true, "false": true, "nil": true, "catch": true, "rescue": true, "after": true, "else": true,
}

func init() {
	register(Language{Name: "elixir", Funcs: template.FuncMap{
		// quote writes a string literal, escaped the way elixir reads it.
		"quote":  elixirQuote,
		"exName": exName,
		// exField is a wire name as the struct key that holds it: detectionId
		// is detection_id.
		"exField": exField,
		"exType":  exType,
		// exFieldRead is a struct key and the expression that reads it, laid out
		// at the indent of a struct's fields.
		"exFieldRead": exFieldRead,
		// exDoc writes a description as an Elixir string, quotes escaped.
		"exDoc": func(text string) string {
			text = strings.TrimSpace(text)
			text = strings.ReplaceAll(text, `\`, `\\`)
			text = strings.ReplaceAll(text, `"`, `\"`)
			text = strings.ReplaceAll(text, "#{", `\#{`)
			return strings.ReplaceAll(text, "\n", " ")
		},
		"exStruct":  exStruct,
		"exTypedoc": exTypedoc,
		"exSpec":    exSpec,
		"exRequest": exRequest,
		// exAtom writes a name as an atom, and exKey as a keyword's key.
		"exAtom": exAtom,
		"exFind": exFind,
	}})
}

// exWidth is the line mix format keeps to.
const exWidth = 98

// exLine writes head, items and tail on one line when it fits in the
// formatter's width at indent, and otherwise one item a line, which mix
// format keeps as it is.
func exLine(indent int, head string, items []string, tail string) string {
	pad := strings.Repeat(" ", indent)
	line := head + strings.Join(items, ", ") + tail
	if len(items) == 0 || indent+utf8.RuneCountInString(line) <= exWidth {
		return pad + line
	}
	return pad + head + "\n" + pad + "  " + strings.Join(items, ",\n"+pad+"  ") + "\n" + pad + tail
}

// exField is the struct key of a wire name.
func exField(wire string) string {
	return exName(strings.ToLower(strings.Join(words(wire), "_")))
}

// exAtom is a name as an atom: :before, or :"a b" when it is not a plain name.
func exAtom(name string) string {
	if identifier.MatchString(name) {
		return ":" + name
	}
	return ":" + elixirQuote(name)
}

// exKey is a name as the key of a keyword list: before:, or "a b":.
func exKey(name string) string {
	if identifier.MatchString(name) {
		return name + ":"
	}
	return elixirQuote(name) + ":"
}

// exFind is the model called name, or nil.
func exFind(models []*Model, name string) *Model {
	for _, model := range models {
		if model.Name == name {
			return model
		}
	}
	return nil
}

// exStruct is a model's defstruct and, for a body, the keys it cannot be
// built without.
func exStruct(m *Model) string {
	var fields, required []string
	for _, f := range m.Fields {
		fields = append(fields, ":"+exField(f.Wire))
		if f.Required && m.Input {
			required = append(required, ":"+exField(f.Wire))
		}
	}
	out := ""
	if len(required) > 0 {
		out = exLine(2, "@enforce_keys [", required, "]") + "\n"
	}
	return out + exLine(2, "defstruct [", fields, "]")
}

// exTypedoc is the @typedoc listing the fields that have something to say:
// a description or the values a string allows. It is empty when none has.
func exTypedoc(m *Model) string {
	var lines []string
	for _, f := range m.Fields {
		var says []string
		if m.Input && !f.Required {
			says = append(says, "optional")
		}
		if len(f.Type.Enum) > 0 {
			values := make([]string, len(f.Type.Enum))
			for i, value := range f.Type.Enum {
				values[i] = "`\"" + value + "\"`"
			}
			says = append(says, "one of "+strings.Join(values, ", "))
		}
		description := strings.TrimSpace(f.Description)
		if len(says) == 0 && description == "" {
			continue
		}
		line := "  * `" + exField(f.Wire) + "`"
		if len(says) > 0 {
			line += " (" + strings.Join(says, "; ") + ")"
		}
		if description != "" {
			line += ": " + exHeredoc(description)
		}
		lines = append(lines, line)
	}
	if len(lines) == 0 {
		return ""
	}
	return "  @typedoc \"\"\"\n" + strings.Join(lines, "\n") + "\n  \"\"\"\n"
}

// exSpec is a service function's @spec, laid out as mix format lays it out:
// on one line, or the answer under it, or every argument on its own line.
// kind is "call", "page" or "stream".
func exSpec(m *Method, kind string) string {
	name := strings.ReplaceAll(strings.ToLower(m.Name), "-", "_")
	args := []string{"Client.t()"}
	for range m.PathParams {
		args = append(args, "String.t()")
	}
	var answer string
	switch kind {
	case "page":
		answer = "{:ok, Alpr.Page.t(Alpr." + m.Item + ".t())} | {:error, Alpr.Error.t()}"
	case "stream":
		name += "_stream"
		answer = "Enumerable.t(Alpr." + m.Item + ".t())"
	default:
		if m.Body != nil {
			args = append(args, "Alpr."+m.Body.Name+".t() | keyword() | map()")
		}
		answer = "{:ok, Alpr." + m.Response + ".t()} | {:error, Alpr.Error.t()}"
		if m.List {
			answer = "{:ok, [Alpr." + m.Item + ".t()]} | {:error, Alpr.Error.t()}"
		}
		if m.NoContent {
			answer = ":ok | {:error, Alpr.Error.t()}"
		}
	}
	args = append(args, "keyword()")
	head := "@spec " + name + "(" + strings.Join(args, ", ") + ")"
	switch {
	case 2+len(head)+4+len(answer) <= exWidth:
		return "  " + head + " :: " + answer
	case 2+len(head)+3 <= exWidth:
		return "  " + head + " ::\n          " + answer
	}
	return "  @spec " + name + "(\n          " + strings.Join(args, ",\n          ") + "\n        ) ::\n          " + answer
}

// exRequest is the options a service function calls Client.request with,
// after the line before it: mix format sets a statement over several lines
// apart with a blank line.
func exRequest(m *Method) string {
	var items []string
	forced := false
	if m.Paginated {
		query := []string{exKey(m.Cursor) + " opts[" + exAtom(m.Cursor) + "]"}
		for _, param := range m.Query {
			query = append(query, exKey(param.Name)+" opts["+exAtom(param.Name)+"]")
		}
		line := exLine(6, "query: [", query, "]")
		forced = strings.Contains(line, "\n")
		items = append(items, strings.TrimLeft(line, " "))
	}
	if m.Body != nil && m.Multipart {
		items = append(items, "multipart: Alpr."+m.Body.Name+".to_form(params)")
	}
	items = append(items, "api_key: opts[:api_key]")
	var request string
	if forced {
		request = "    request = [\n      " + strings.Join(items, ",\n      ") + "\n    ]"
	} else {
		request = exLine(4, "request = [", items, "]")
	}
	if strings.Contains(request, "\n") {
		return "\n\n" + request
	}
	return "\n" + request
}

// exName is a wire name as an Elixir variable.
func exName(name string) string {
	name = strings.ReplaceAll(name, "-", "_")
	if exReserved[name] {
		return name + "_"
	}
	return name
}

// exType is a field's typespec. A string's allowed values are documented,
// not atoms: what the API sends is kept as it was sent.
func exType(t *TypeRef) string {
	switch t.Kind {
	case "string":
		return "String.t()"
	case "integer":
		return "integer()"
	case "number":
		return "number()"
	case "boolean":
		return "boolean()"
	case "binary":
		return "binary()"
	case "model":
		return "Alpr." + t.Model + ".t()"
	case "array":
		return "[" + exType(t.Items) + "]"
	case "map":
		return "%{optional(String.t()) => " + exType(t.Items) + "}"
	case "any":
		return "term()"
	}
	return "term()"
}

// exRead is the expression that reads a field out of the API's map into its
// type: a nested model is built, anything else is taken as it is. A field the
// answer leaves out, or sends as null, is nil.
func exRead(f *Field) (string, string) {
	value := `data["` + f.Wire + `"]`
	if convert := exConvert(f.Type, "value", 0); convert != "" {
		return "value when not is_nil(value) <- " + value, "do: " + convert
	}
	return value, ""
}

// exFieldRead is a struct key and its expression, at the indent of a struct's
// fields (6) and as mix format lays it out when the line is too long.
func exFieldRead(f *Field) string {
	key := exField(f.Wire) + ":"
	match, do := exRead(f)
	if do == "" {
		return "      " + key + " " + match
	}
	single := "      " + key + " with(" + match + ", " + do + ")"
	if utf8.RuneCountInString(single)+1 <= exWidth {
		return single
	}
	return "      " + key + "\n        with(\n          " + match + ",\n          " + do + "\n        )"
}

// exConvert builds expr into t, or is empty when nothing is to be built.
func exConvert(t *TypeRef, expr string, depth int) string {
	each := "item" + strings.Repeat("_", depth)
	switch t.Kind {
	case "model":
		return "Alpr." + t.Model + ".from_map(" + expr + ")"
	case "array":
		if t.Items.Kind == "model" {
			return "Enum.map(" + expr + ", &Alpr." + t.Items.Model + ".from_map/1)"
		}
		if inner := exConvert(t.Items, each, depth+1); inner != "" {
			return "Enum.map(" + expr + ", fn " + each + " -> " + inner + " end)"
		}
	case "map":
		if inner := exConvert(t.Items, each, depth+1); inner != "" {
			return "Map.new(" + expr + ", fn {key, " + each + "} -> {key, " + inner + "} end)"
		}
	}
	return ""
}

// exHeredoc is text on one line inside a """ heredoc, where a backslash starts
// an escape and #{ interpolates.
func exHeredoc(text string) string {
	text = strings.NewReplacer(`\`, `\\`, "#{", `\#{`, `"""`, `\"\"\"`).Replace(text)
	return strings.Join(strings.Fields(text), " ")
}
