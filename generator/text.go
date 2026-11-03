package generator

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode"
)

// The contract is input, and its text ends up inside the SDKs' source: in
// identifiers, in string literals and in comments. Three defences keep a
// hostile or merely odd contract from becoming code in a published package.
//
//  1. Everything that becomes an identifier, a path or a literal is checked
//     against a narrow alphabet when the contract is read, and generation
//     fails if it does not match (the checks below).
//  2. A string literal is always written by the language's own quoting
//     function (the *Quote functions below), never by wrapping text in quotes.
//  3. Free text (a description, a summary) is cleaned when the contract is
//     read, and each language's comment helper writes what is left.
var (
	// identifier is a model, a field, a query or a path parameter name.
	identifier = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	// slug is a service or a method name; customer-sessions has a hyphen.
	slug = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]*$`)
	// enumValue is an allowed value of a string field, which also names a
	// constant in several languages.
	enumValue = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)
	// eventType is a webhook's type: order.created.
	eventType = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$`)
	// pathLiteral is the literal part of a request path.
	pathLiteral = regexp.MustCompile(`^[A-Za-z0-9_./~-]*$`)
	// baseURL is the address of the API, or empty.
	baseURL = regexp.MustCompile(`^(https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?)?$`)
	// versionText is an SDK or contract version.
	versionText = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._+-]*$`)
)

func checkIdentifier(what, value string) error {
	if !identifier.MatchString(value) {
		return fmt.Errorf("generator: %s %q is not an identifier (letters, digits and _, not starting with a digit)", what, value)
	}
	return nil
}

func checkMatch(what, value string, pattern *regexp.Regexp) error {
	if !pattern.MatchString(value) {
		return fmt.Errorf("generator: %s %q has characters an SDK cannot carry safely", what, value)
	}
	return nil
}

// checkPath says a request path is literal text and {parameters} that are
// identifiers, and nothing else.
func checkPath(path string) error {
	if !strings.HasPrefix(path, "/") {
		return fmt.Errorf("generator: path %q does not start with /", path)
	}
	rest := path
	for rest != "" {
		open := strings.IndexAny(rest, "{}")
		if open < 0 {
			return checkMatch("path", rest, pathLiteral)
		}
		if rest[open] == '}' {
			return fmt.Errorf("generator: path %q has a } without a {", path)
		}
		if err := checkMatch("path", rest[:open], pathLiteral); err != nil {
			return err
		}
		end := strings.IndexByte(rest[open:], '}')
		if end < 0 {
			return fmt.Errorf("generator: path %q has a { without a }", path)
		}
		if err := checkIdentifier("path parameter", rest[open+1:open+end]); err != nil {
			return err
		}
		rest = rest[open+end+1:]
	}
	return nil
}

// cleanText makes free text safe to put in a comment of any language. Line
// endings become \n, and the characters some compilers read as one, control
// characters and the bidirectional overrides that make code read differently
// from how it runs are dropped, and the sequences that end a comment or a
// docstring are broken. A language's comment helper still escapes what is
// specific to it.
func cleanText(text string) string {
	text = strings.NewReplacer("\r\n", "\n", "\r", "\n", "\u0085", "\n", " ", "\n", " ", "\n", "\t", " ").Replace(text)
	text = strings.Map(func(r rune) rune {
		switch {
		case r == '\n':
			return r
		case unicode.IsControl(r), r >= 0x202A && r <= 0x202E, r >= 0x2066 && r <= 0x2069, r == 0xFEFF:
			return -1
		}
		return r
	}, text)
	text = strings.NewReplacer("*/", "* /", "/*", "/ *", `"""`, `" ""`, "'''", `' ''`, "]]>", "] ]>").Replace(text)
	return strings.TrimSpace(text)
}

// cleanLine is cleanText for text that is one line, such as a summary.
func cleanLine(text string) string {
	return strings.Join(strings.Fields(cleanText(text)), " ")
}

// quoter writes a string literal.
type quoter struct {
	// quote is the delimiter: ' or ".
	quote rune
	// escapes are the characters written as a backslash and a letter.
	escapes map[rune]string
	// control writes any other character that cannot stand in a literal.
	control func(r rune) string
	// interpolation lists the sequences the language reads inside a literal
	// and that are kept as text by a backslash before their first character.
	interpolation []string
	// dollar escapes $ (Dart reads $name inside a literal).
	dollar bool
}

func (q quoter) literal(text string) string {
	var b strings.Builder
	b.WriteRune(q.quote)
	runes := []rune(text)
	for i, r := range runes {
		switch {
		case r == '\\' || r == q.quote:
			b.WriteByte('\\')
			b.WriteRune(r)
		case q.dollar && r == '$':
			b.WriteString(`\$`)
		case q.escapes[r] != "":
			b.WriteString(q.escapes[r])
		case r < 0x20 || r == 0x7f || r == 0x85 || r == 0x2028 || r == 0x2029:
			b.WriteString(q.control(r))
		default:
			for _, sequence := range q.interpolation {
				if strings.HasPrefix(string(runes[i:]), sequence) {
					b.WriteByte('\\')
					break
				}
			}
			b.WriteRune(r)
		}
	}
	b.WriteRune(q.quote)
	return b.String()
}

var common = map[rune]string{'\n': `\n`, '\r': `\r`, '\t': `\t`}

func escapesWith(extra map[rune]string) map[rune]string {
	out := map[rune]string{}
	for r, s := range common {
		out[r] = s
	}
	for r, s := range extra {
		out[r] = s
	}
	return out
}

func hex(format string) func(rune) string {
	return func(r rune) string { return fmt.Sprintf(format, r) }
}

var (
	// goQuote is Go's own.
	goQuote = strconv.Quote

	tsQuote     = quoter{quote: '"', escapes: escapesWith(map[rune]string{'\b': `\b`, '\f': `\f`, '\v': `\v`}), control: hex(`\u%04X`)}.literal
	pythonQuote = quoter{quote: '"', escapes: escapesWith(nil), control: hex(`\x%02X`)}.literal
	// Ruby and Elixir read #{…} inside double quotes; Ruby also #$ and #@.
	rubyQuote   = quoter{quote: '"', escapes: escapesWith(map[rune]string{0x1b: `\e`}), control: hex(`\x%02X`), interpolation: []string{"#{", "#$", "#@"}}.literal
	elixirQuote = quoter{quote: '"', escapes: escapesWith(nil), control: hex(`\x%02X`), interpolation: []string{"#{"}}.literal
	// A PHP single-quoted string reads only \\ and \'.
	phpQuote  = quoter{quote: '\'', escapes: map[rune]string{}, control: func(r rune) string { return string(r) }}.literal
	javaQuote = quoter{quote: '"', escapes: escapesWith(map[rune]string{'\b': `\b`, '\f': `\f`}), control: func(r rune) string { return fmt.Sprintf(`\%03o`, r) }}.literal
	// C# has no octal escape and \x takes a variable number of digits.
	csharpQuote = quoter{quote: '"', escapes: escapesWith(map[rune]string{'\b': `\b`, '\f': `\f`, '\v': `\v`, '\a': `\a`, 0: `\0`}), control: hex(`\u%04X`)}.literal
	rustQuote   = quoter{quote: '"', escapes: escapesWith(map[rune]string{0: `\0`}), control: hex(`\u{%x}`)}.literal
	swiftQuote  = quoter{quote: '"', escapes: escapesWith(map[rune]string{0: `\0`}), control: hex(`\u{%x}`)}.literal
	dartQuote   = quoter{quote: '\'', escapes: escapesWith(map[rune]string{'\b': `\b`, '\f': `\f`, '\v': `\v`}), control: hex(`\x%02X`), dollar: true}.literal
)

// inner is a literal without its delimiters, to be spliced into a larger one.
func inner(literal string) string { return literal[1 : len(literal)-1] }
