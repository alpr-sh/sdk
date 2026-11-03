// Package generator builds Alpr.sh's SDKs from the public API's contract, the
// way Polar builds its own: the OpenAPI document is read into an
// intermediate representation that no language knows about -- services,
// methods, models, pagination -- and one emitter per language renders it.
// The SDKs under sdk/<language> are output and are never edited by hand;
// what is hand-written lives in this package's templates.
package generator

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// IR is the API as every SDK sees it.
type IR struct {
	// Version is the SDK's version, the same in every language.
	Version string
	// APIVersion is the contract's info.version.
	APIVersion string
	BaseURL    string
	Models     []*Model
	Services   []*Service
	// Webhooks are the events the API posts to an endpoint, grouped by the
	// payload they carry.
	Webhooks []*WebhookGroup
	// WebhookField is the body field that names the event: "event".
	WebhookField string
}

// WebhookGroup is the events whose body is one payload: each SDK declares one
// event type a group, and the union of them is what a verified webhook
// answers. The body's event field tells the members of a group apart.
type WebhookGroup struct {
	// Name names the group's event type, the payload model's: RecognitionCreated
	// is RecognitionCreatedWebhookEvent.
	Name string
	// Model is the payload's model.
	Model string
	// Types are the event names the group carries, sorted.
	Types []string
}

// Model is a named object: a resource the API answers, or the body of a
// request.
type Model struct {
	Name        string
	Description string
	Fields      []*Field
	// Input says the model is sent, not read.
	Input bool
}

// Field is one property of a model.
type Field struct {
	// Wire is the JSON name.
	Wire        string
	Description string
	Type        *TypeRef
	Required    bool
	Nullable    bool
}

// TypeRef is a field's type.
type TypeRef struct {
	// Kind is string, integer, number, boolean, binary (a file sent in a
	// multipart body), model, array, map or any: a free-form JSON value,
	// which a schema with no type allows.
	Kind  string
	Model string
	Items *TypeRef
	// Enum are a string's allowed values.
	Enum   []string
	Format string
}

// Service groups the methods of one resource: photos, recognitions.
type Service struct {
	Name    string
	Methods []*Method
}

// Method kinds: what the answer is.
const (
	// KindObject answers one model.
	KindObject = "object"
	// KindList answers {"data": [item]}: every item, no more pages.
	KindList = "list"
	// KindPage answers {"data": [item], "next": cursor}: a page, and the
	// cursor of the next one.
	KindPage = "page"
	// KindNone answers a 204.
	KindNone = "none"
)

// Method is one operation.
type Method struct {
	// Name is the part of the operationId after the service: list, get.
	Name        string
	OperationID string
	Summary     string
	HTTPMethod  string
	Path        string
	PathParams  []string
	// Query are the optional filters, without the cursor.
	Query []*Param
	// Body is the request model, or nil.
	Body *Model
	// Multipart says Body is sent as multipart/form-data: its binary field is
	// the file, the rest are text fields.
	Multipart bool
	// Kind says what the answer is.
	Kind string
	// Response is the model answered; for a list or a page, the model of one
	// item.
	Response string
	// Paginated says the answer is a page of Item.
	Paginated bool
	Item      string
	// Cursor is the query parameter that carries the cursor to ask for the
	// next page with, and Next the answer's field that holds it.
	Cursor, Next string
	// List says the answer is the items of {"data": [item]}.
	List bool
	// Write says the method changes something (it is not a GET).
	Write bool
	// NoContent says the answer is a 204 with no body, so the method returns
	// nothing.
	NoContent bool
}

// Param is a query filter.
type Param struct {
	Name, Description string
}

type spec struct {
	Info struct {
		Version string `json:"version"`
	} `json:"info"`
	Servers []struct {
		URL string `json:"url"`
	} `json:"servers"`
	Paths      map[string]map[string]*operation `json:"paths"`
	Webhooks   map[string]map[string]*operation `json:"webhooks"`
	Components struct {
		Schemas map[string]*schema `json:"schemas"`
	} `json:"components"`
}

type operation struct {
	OperationID string                `json:"operationId"`
	Summary     string                `json:"summary"`
	Security    []map[string][]string `json:"security"`
	Parameters  []struct {
		Name        string  `json:"name"`
		In          string  `json:"in"`
		Description string  `json:"description"`
		Schema      *schema `json:"schema"`
	} `json:"parameters"`
	RequestBody *struct {
		Content map[string]struct {
			Schema *schema `json:"schema"`
		} `json:"content"`
	} `json:"requestBody"`
	Responses map[string]struct {
		Content map[string]struct {
			Schema *schema `json:"schema"`
		} `json:"content"`
	} `json:"responses"`
	// RouteName is the name of the route the operation documents, which the
	// documentation generator writes: api.recognize.
	RouteName string `json:"x-arandu-route-name"`
	// Pagination optionally names the cursor parameter, the answer's next
	// field and the item: the SDK reads them from the shape when it is absent.
	Pagination map[string]string `json:"x-alpr-pagination"`
}

type schema struct {
	Ref         string `json:"$ref"`
	Type        any    `json:"type"`
	Format      string `json:"format"`
	Description string `json:"description"`
	// Enum has nil for the null a nullable schema lists among its values.
	Enum       []*string          `json:"enum"`
	Required   []string           `json:"required"`
	Properties map[string]*schema `json:"properties"`
	Items      *schema            `json:"items"`
	AnyOf      []*schema          `json:"anyOf"`
	OneOf      []*schema          `json:"oneOf"`
	// AdditionalProperties is a schema, or false for a closed object.
	AdditionalProperties json.RawMessage `json:"additionalProperties"`
}

// free says the schema constrains nothing: no type, no shape, no values. Its
// value is any JSON.
func (s *schema) free() bool {
	return s.Type == nil && s.Ref == "" && len(s.Properties) == 0 && s.Items == nil && len(s.Enum) == 0 && s.Format == "" &&
		len(s.AnyOf) == 0 && len(s.OneOf) == 0 && s.additional() == nil && len(s.AdditionalProperties) == 0
}

// additional is the schema of a map's values, or nil.
func (s *schema) additional() *schema {
	raw := strings.TrimSpace(string(s.AdditionalProperties))
	if raw == "" || !strings.HasPrefix(raw, "{") {
		return nil
	}
	var values schema
	if json.Unmarshal(s.AdditionalProperties, &values) != nil {
		return nil
	}
	return &values
}

// Load reads the contract at path into the IR.
func Load(path, version string) (*IR, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc spec
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("generator: read %s: %w", path, err)
	}
	return build(&doc, version)
}

// wrapper says a component schema is not a model the SDKs expose: the error
// body, which each SDK's hand-written runtime turns into its own error type,
// and the {"data": [...]} list an operation answers, which the SDKs unwrap.
func wrapper(name string, s *schema) bool {
	if name == "Error" {
		return true
	}
	data := s.Properties["data"]
	return data != nil && (data.Type == "array") && len(s.Properties) <= 2
}

// loader reads schemas into types, knowing which named schemas are not
// models but maps: an object with no properties whose values are all of one
// type is that map wherever it is referenced.
type loader struct {
	doc     *spec
	aliases map[string]*schema
	// synthesized are the models an inline object schema became, by name.
	synthesized map[string]*Model
}

func newLoader(doc *spec) *loader {
	l := &loader{doc: doc, aliases: map[string]*schema{}, synthesized: map[string]*Model{}}
	for name, s := range doc.Components.Schemas {
		if len(s.Properties) == 0 && s.additional() != nil {
			l.aliases[name] = s
		}
	}
	return l
}

// resolve follows a $ref to a component schema.
func (l *loader) resolve(s *schema) (*schema, string) {
	if s == nil || s.Ref == "" {
		return s, ""
	}
	name := strings.TrimPrefix(s.Ref, "#/components/schemas/")
	if target := l.doc.Components.Schemas[name]; target != nil {
		return target, name
	}
	return s, name
}

func build(doc *spec, version string) (*IR, error) {
	ir := &IR{Version: version, APIVersion: doc.Info.Version, WebhookField: "event"}
	if len(doc.Servers) > 0 {
		ir.BaseURL = doc.Servers[0].URL
	}
	for what, check := range map[string]struct {
		value   string
		pattern *regexp.Regexp
	}{"SDK version": {ir.Version, versionText}, "contract version": {ir.APIVersion, versionText}, "server address": {ir.BaseURL, baseURL}} {
		if err := checkMatch(what, check.value, check.pattern); err != nil {
			return nil, err
		}
	}
	l := newLoader(doc)
	services := map[string]*Service{}
	paths := make([]string, 0, len(doc.Paths))
	for path := range doc.Paths {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		methods := make([]string, 0, len(doc.Paths[path]))
		for method := range doc.Paths[path] {
			methods = append(methods, method)
		}
		sort.Strings(methods)
		for _, httpMethod := range methods {
			op := doc.Paths[path][httpMethod]
			if !apiKeyOperation(op) {
				continue
			}
			if !httpMethods[httpMethod] {
				return nil, fmt.Errorf("generator: %s is not an HTTP method the SDKs send (%s)", httpMethod, path)
			}
			if err := checkPath(path); err != nil {
				return nil, err
			}
			serviceName, methodName, err := namesOf(op, strings.ToUpper(httpMethod), path)
			if err != nil {
				return nil, err
			}
			if err := checkMatch("service", serviceName, slug); err != nil {
				return nil, err
			}
			if err := checkMatch("method", methodName, slug); err != nil {
				return nil, err
			}
			method, err := l.methodOf(op, strings.ToUpper(httpMethod), path, serviceName, methodName)
			if err != nil {
				return nil, err
			}
			service := services[serviceName]
			if service == nil {
				service = &Service{Name: serviceName}
				services[serviceName] = service
			}
			service.Methods = append(service.Methods, method)
			if method.Body != nil {
				ir.Models = append(ir.Models, method.Body)
			}
		}
	}
	serviceNames := make([]string, 0, len(services))
	for name := range services {
		serviceNames = append(serviceNames, name)
	}
	sort.Strings(serviceNames)
	for _, name := range serviceNames {
		service := services[name]
		sort.Slice(service.Methods, func(i, j int) bool { return service.Methods[i].Name < service.Methods[j].Name })
		ir.Services = append(ir.Services, service)
	}
	webhooks, err := l.webhooks(doc)
	if err != nil {
		return nil, err
	}
	ir.Webhooks = webhooks
	// The models are the ones the services and the webhooks reach, named
	// components and inline objects alike: the rest of the contract (the
	// partner API's, the previous platform's) is not the SDK's.
	var roots []string
	for _, service := range ir.Services {
		for _, method := range service.Methods {
			if method.Response != "" {
				roots = append(roots, method.Response)
			}
		}
	}
	for _, group := range ir.Webhooks {
		roots = append(roots, group.Model)
	}
	reached := map[string]*Model{}
	for _, model := range ir.Models {
		reached[model.Name] = model
	}
	for _, model := range l.synthesized {
		reached[model.Name] = model
	}
	var models []*Model
	seen := map[string]bool{}
	var visit func(name string) error
	visit = func(name string) error {
		if seen[name] {
			return nil
		}
		seen[name] = true
		model := reached[name]
		if model == nil {
			schema := doc.Components.Schemas[name]
			if schema == nil {
				return fmt.Errorf("generator: model %s is not in the contract", name)
			}
			var err error
			if model, err = l.modelOf(name, schema, false); err != nil {
				return err
			}
			// Inline objects found while reading it are reached too.
			for _, synthesized := range l.synthesized {
				reached[synthesized.Name] = synthesized
			}
		}
		models = append(models, model)
		for _, field := range model.Fields {
			for t := field.Type; t != nil; t = t.Items {
				if t.Kind == "model" {
					if err := visit(t.Model); err != nil {
						return err
					}
				}
			}
		}
		return nil
	}
	for _, name := range roots {
		if err := visit(name); err != nil {
			return nil, err
		}
	}
	for _, model := range ir.Models {
		if model.Input {
			models = append(models, model)
		}
	}
	// Inline models found after their parent was visited.
	for name := range l.synthesized {
		if !seen[name] {
			for _, model := range models {
				if model.Name == name {
					seen[name] = true
				}
			}
			if !seen[name] {
				if err := visit(name); err != nil {
					return nil, err
				}
			}
		}
	}
	ir.Models = models
	sort.Slice(ir.Models, func(i, j int) bool { return ir.Models[i].Name < ir.Models[j].Name })
	return ir, nil
}

// httpMethods are the verbs an SDK sends.
var httpMethods = map[string]bool{"get": true, "post": true, "put": true, "patch": true, "delete": true}

// routeNames name the operations of the public API by the route the
// documentation generator names them after, for a contract whose operations
// carry no "service:method" operationId.
var routeNames = map[string]string{
	"api.recognize":         "photos:recognize",
	"api.detect":            "photos:detect",
	"api.ocr":               "photos:ocr",
	"api.recognitions":      "recognitions:list",
	"api.cameras":           "cameras:list",
	"api.detections.image":  "detections:image",
	"api.recognitions.show": "recognitions:get",
}

// namesOf is an operation's service and method: the operationId
// "service:method", or the known route's, or the first literal segment of the
// path and a verb.
func namesOf(op *operation, httpMethod, path string) (string, string, error) {
	if service, method, ok := strings.Cut(op.OperationID, ":"); ok {
		return service, method, nil
	}
	if named, ok := routeNames[op.RouteName]; ok {
		service, method, _ := strings.Cut(named, ":")
		return service, method, nil
	}
	var literals []string
	param := false
	for _, segment := range strings.Split(strings.Trim(path, "/"), "/") {
		switch {
		case segment == "api" || segment == "partner" || regexp.MustCompile(`^v[0-9]+$`).MatchString(segment):
		case strings.HasPrefix(segment, "{"):
			param = true
		default:
			literals = append(literals, segment)
		}
	}
	if len(literals) == 0 {
		return "", "", fmt.Errorf("generator: %s %s has no service:method operationId and no name to derive one from", httpMethod, path)
	}
	service := literals[0]
	if len(literals) > 1 {
		return service, strings.Join(literals[1:], "-"), nil
	}
	switch {
	case httpMethod == "GET" && param:
		return service, "get", nil
	case httpMethod == "GET":
		return service, "list", nil
	case httpMethod == "POST":
		return service, "create", nil
	case httpMethod == "DELETE":
		return service, "delete", nil
	}
	return service, "update", nil
}

// webhooks reads the contract's webhooks: each event a POST whose body is
// the payload, flat, with its event field naming the one event it is.
func (l *loader) webhooks(doc *spec) ([]*WebhookGroup, error) {
	groups := map[string]*WebhookGroup{}
	for name, item := range doc.Webhooks {
		if err := checkMatch("webhook", name, eventType); err != nil {
			return nil, err
		}
		op := item["post"]
		if op == nil || op.RequestBody == nil {
			return nil, fmt.Errorf("generator: webhook %s is not a POST with a body", name)
		}
		if !signedLikeTheSDK(op) {
			// Another delivery with its own headers and signature (the
			// previous platform's, a partner's): not what VerifyWebhook reads.
			continue
		}
		body := op.RequestBody.Content["application/json"].Schema
		if body == nil || body.Ref == "" {
			return nil, fmt.Errorf("generator: webhook %s has no payload model", name)
		}
		payload, model := l.resolve(body)
		if payload == nil || payload.Properties["event"] == nil {
			return nil, fmt.Errorf("generator: webhook %s has no event field", name)
		}
		if enum := payload.Properties["event"].Enum; len(enum) != 1 || enum[0] == nil || *enum[0] != name {
			return nil, fmt.Errorf("generator: webhook %s declares an event other than it", name)
		}
		if err := checkIdentifier("webhook payload of "+name, model); err != nil {
			return nil, err
		}
		group := strings.TrimPrefix(model, "Webhook")
		if group == "" {
			group = model
		}
		if groups[model] == nil {
			groups[model] = &WebhookGroup{Name: group, Model: model}
		}
		groups[model].Types = append(groups[model].Types, name)
	}
	out := make([]*WebhookGroup, 0, len(groups))
	for _, group := range groups {
		if err := checkIdentifier("webhook group", group.Name); err != nil {
			return nil, err
		}
		sort.Strings(group.Types)
		out = append(out, group)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// signedLikeTheSDK says a webhook carries the headers the SDK verifies: the
// delivery id, the timestamp and the signature under the X-Alprsh prefix.
func signedLikeTheSDK(op *operation) bool {
	for _, param := range op.Parameters {
		if param.In == "header" && strings.EqualFold(param.Name, "X-Alprsh-Delivery-Id") {
			return true
		}
	}
	return false
}

// apiKeyOperation says the operation is the SDK's: authenticated by the
// workspace's API key. The partner API takes the partner's credentials and is
// not.
func apiKeyOperation(op *operation) bool {
	for _, requirement := range op.Security {
		if _, ok := requirement["apiKey"]; ok {
			return true
		}
	}
	return false
}

// cursorParams are the query parameters that carry a cursor.
var cursorParams = map[string]bool{"before": true, "after": true, "cursor": true, "starting_after": true}

func (l *loader) methodOf(op *operation, httpMethod, path, serviceName, methodName string) (*Method, error) {
	method := &Method{Name: methodName, OperationID: op.OperationID, Summary: cleanLine(op.Summary), HTTPMethod: httpMethod, Path: path,
		Write: httpMethod != "GET"}
	if method.OperationID == "" {
		method.OperationID = serviceName + ":" + methodName
	}
	var cursor string
	for _, param := range op.Parameters {
		switch {
		case param.In == "path":
			if err := checkIdentifier("path parameter", param.Name); err != nil {
				return nil, err
			}
			method.PathParams = append(method.PathParams, param.Name)
		case param.In == "query":
			if err := checkIdentifier("query parameter", param.Name); err != nil {
				return nil, err
			}
			if cursorParams[param.Name] {
				cursor = param.Name
				continue
			}
			method.Query = append(method.Query, &Param{Name: param.Name, Description: cleanText(param.Description)})
		}
	}
	for status, response := range op.Responses {
		if !strings.HasPrefix(status, "2") {
			continue
		}
		if status == "204" {
			method.NoContent = true
			method.Kind = KindNone
			continue
		}
		answer := response.Content["application/json"].Schema
		if answer == nil {
			return nil, fmt.Errorf("generator: %s answers %s with no JSON body", op.OperationID, status)
		}
		if err := l.answer(method, op, answer, serviceName, methodName, cursor); err != nil {
			return nil, err
		}
	}
	if method.Kind == "" {
		return nil, fmt.Errorf("generator: %s answers no model", op.OperationID)
	}
	if len(method.Query) > 0 && !method.Paginated {
		return nil, fmt.Errorf("generator: %s has query parameters, which the SDKs carry only on a page", method.OperationID)
	}
	if op.RequestBody != nil {
		// A photo can be sent several ways; the SDKs send it as multipart.
		content, kind := op.RequestBody.Content["multipart/form-data"], "multipart/form-data"
		if content.Schema == nil {
			content, kind = op.RequestBody.Content["application/json"], "application/json"
		}
		body, _ := l.resolve(content.Schema)
		if body != nil && len(body.Properties) > 0 && kind != "multipart/form-data" {
			return nil, fmt.Errorf("generator: %s sends a JSON body, which the SDKs do not carry yet: the API takes photos as multipart", method.OperationID)
		}
		if body != nil && len(body.Properties) > 0 {
			model, err := l.modelOf(Pascal(serviceName)+Pascal(methodName)+"Params", body, true)
			if err != nil {
				return nil, err
			}
			model.Description = "The body of " + method.OperationID + "."
			method.Body = model
			method.Multipart = true
		}
	}
	return method, nil
}

// answer reads what a 2xx answers into the method: one model, the items of
// {"data": [...]}, or a page of them with the cursor of the next.
func (l *loader) answer(method *Method, op *operation, answer *schema, serviceName, methodName, cursor string) error {
	body, ref := l.resolve(answer)
	if body == nil {
		return fmt.Errorf("generator: %s answers no schema", op.OperationID)
	}
	if data := body.Properties["data"]; data != nil && data.Type == "array" && data.Items != nil && len(body.Properties) <= 2 {
		hint := Pascal(singular(serviceName))
		item, _, err := l.typeOf(data.Items, hint)
		if err != nil {
			return fmt.Errorf("generator: %s: %w", op.OperationID, err)
		}
		if item.Kind != "model" {
			return fmt.Errorf("generator: %s lists something that is not a model", op.OperationID)
		}
		method.Response, method.Item = item.Model, item.Model
		method.Kind, method.List = KindList, true
		if next := body.Properties["next"]; next != nil {
			method.Kind, method.List, method.Paginated = KindPage, false, true
			method.Next = "next"
			method.Cursor = cursor
			if method.Cursor == "" {
				method.Cursor = "before"
			}
			if named := op.Pagination["cursor"]; named != "" {
				method.Cursor = named
			}
			if named := op.Pagination["next"]; named != "" {
				method.Next = named
			}
			if item := op.Pagination["item_schema"]; item != "" && item != method.Item {
				return fmt.Errorf("generator: %s pages %q but declares %q", op.OperationID, method.Item, item)
			}
		}
		return nil
	}
	typ, _, err := l.typeOf(answer, Pascal(serviceName)+Pascal(methodName)+"Result")
	if err != nil {
		return fmt.Errorf("generator: %s: %w", op.OperationID, err)
	}
	if typ.Kind != "model" {
		return fmt.Errorf("generator: %s answers no model (%s)", op.OperationID, ref)
	}
	if err := checkIdentifier("response model of "+op.OperationID, typ.Model); err != nil {
		return err
	}
	method.Kind, method.Response = KindObject, typ.Model
	return nil
}

func (l *loader) modelOf(name string, s *schema, input bool) (*Model, error) {
	if err := checkIdentifier("model", name); err != nil {
		return nil, err
	}
	model := &Model{Name: name, Description: cleanText(s.Description), Input: input}
	required := map[string]bool{}
	for _, field := range s.Required {
		required[field] = true
	}
	wires := make([]string, 0, len(s.Properties))
	for wire := range s.Properties {
		wires = append(wires, wire)
	}
	sort.Strings(wires)
	for _, wire := range wires {
		property := s.Properties[wire]
		if err := checkIdentifier("field of "+name, wire); err != nil {
			return nil, err
		}
		typ, nullable, err := l.typeOf(property, name+Pascal(wire))
		if err != nil {
			return nil, fmt.Errorf("generator: %s.%s: %w", name, wire, err)
		}
		model.Fields = append(model.Fields, &Field{Wire: wire, Description: cleanText(property.Description), Type: typ, Required: required[wire], Nullable: nullable})
	}
	return model, nil
}

// typeOf is a schema's type. An object with properties that has no name of
// its own becomes a model named hint.
func (l *loader) typeOf(s *schema, hint string) (*TypeRef, bool, error) {
	if s.Ref != "" {
		name := strings.TrimPrefix(s.Ref, "#/components/schemas/")
		if alias := l.aliases[name]; alias != nil {
			return l.typeOf(alias, hint)
		}
		if err := checkIdentifier("referenced model", name); err != nil {
			return nil, false, err
		}
		return &TypeRef{Kind: "model", Model: name}, false, nil
	}
	if alternatives := append(append([]*schema{}, s.AnyOf...), s.OneOf...); len(alternatives) > 0 {
		var rest []*schema
		nullable := false
		for _, each := range alternatives {
			if each.Type == "null" {
				nullable = true
			} else {
				rest = append(rest, each)
			}
		}
		if len(rest) != 1 {
			return &TypeRef{Kind: "any"}, nullable, nil
		}
		typ, inner, err := l.typeOf(rest[0], hint)
		return typ, nullable || inner, err
	}
	kind, nullable := "", false
	switch t := s.Type.(type) {
	case string:
		kind = t
	case []any:
		for _, each := range t {
			if each == "null" {
				nullable = true
			} else {
				kind, _ = each.(string)
			}
		}
	}
	if kind == "" && s.free() {
		return &TypeRef{Kind: "any"}, false, nil
	}
	switch kind {
	case "string", "integer", "number", "boolean":
		var enum []string
		for _, value := range s.Enum {
			if value == nil {
				// null among the values is the nullability, not a value.
				nullable = true
				continue
			}
			if err := checkMatch("allowed value", *value, enumValue); err != nil {
				return nil, false, err
			}
			enum = append(enum, *value)
		}
		if kind == "string" && s.Format == "binary" {
			return &TypeRef{Kind: "binary", Format: s.Format}, nullable, nil
		}
		return &TypeRef{Kind: kind, Enum: enum, Format: s.Format}, nullable, nil
	case "array":
		if s.Items == nil {
			return &TypeRef{Kind: "array", Items: &TypeRef{Kind: "any"}}, nullable, nil
		}
		items, _, err := l.typeOf(s.Items, singular(hint))
		return &TypeRef{Kind: "array", Items: items}, nullable, err
	case "object":
		if values := s.additional(); values != nil {
			items, _, err := l.typeOf(values, hint+"Value")
			return &TypeRef{Kind: "map", Items: items}, nullable, err
		}
		if len(s.Properties) == 0 {
			// An object that names no property, closed or not, is the pairs
			// the caller chooses: a map of free-form values.
			return &TypeRef{Kind: "map", Items: &TypeRef{Kind: "any"}}, nullable, nil
		}
		if hint == "" {
			return nil, false, fmt.Errorf("an object with properties and no name")
		}
		if l.synthesized[hint] == nil {
			// Registered before it is read, so a name cannot be taken twice.
			l.synthesized[hint] = &Model{Name: hint}
			model, err := l.modelOf(hint, s, false)
			if err != nil {
				return nil, false, err
			}
			l.synthesized[hint] = model
		}
		return &TypeRef{Kind: "model", Model: hint}, nullable, nil
	}
	return nil, false, fmt.Errorf("unsupported schema type %v", s.Type)
}

// singular writes a plural name as the noun of one: plates as plate.
func singular(name string) string {
	switch {
	case strings.HasSuffix(name, "ies"):
		return strings.TrimSuffix(name, "ies") + "y"
	case strings.HasSuffix(name, "ses"), strings.HasSuffix(name, "ss"):
		return name
	case strings.HasSuffix(name, "s"):
		return strings.TrimSuffix(name, "s")
	}
	return name
}

// acronyms are the words written in capitals inside a name: detectionId is
// DetectionID.
var acronyms = map[string]bool{"id": true, "url": true, "uri": true, "api": true, "ocr": true, "lpr": true, "roi": true, "ip": true}

// words splits a name at _, -, ., spaces and the starts of camelCase words.
func words(name string) []string {
	var out []string
	for _, part := range strings.FieldsFunc(name, func(r rune) bool { return r == '_' || r == '-' || r == '.' || r == ' ' }) {
		start := 0
		runes := []rune(part)
		for i := 1; i < len(runes); i++ {
			if unicode.IsUpper(runes[i]) && !unicode.IsUpper(runes[i-1]) {
				out = append(out, string(runes[start:i]))
				start = i
			}
		}
		out = append(out, string(runes[start:]))
	}
	return out
}

// Pascal writes payment_methods as PaymentMethods and detectionId as
// DetectionID.
func Pascal(name string) string {
	parts := words(name)
	for i, part := range parts {
		if acronyms[strings.ToLower(part)] {
			parts[i] = strings.ToUpper(part)
		} else {
			parts[i] = strings.ToUpper(part[:1]) + part[1:]
		}
	}
	return strings.Join(parts, "")
}

// Camel writes payment_methods as paymentMethods and ocr as ocr.
func Camel(name string) string {
	parts := words(name)
	if len(parts) == 0 {
		return ""
	}
	first := strings.ToLower(parts[0][:1]) + parts[0][1:]
	if acronyms[strings.ToLower(parts[0])] {
		first = strings.ToLower(parts[0])
	}
	return first + Pascal(strings.Join(parts[1:], "_"))
}
