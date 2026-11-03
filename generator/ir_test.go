package generator

import "testing"

// The contract the API serves reads into services and models: photos sent as
// multipart, the readings as a page over a cursor, the cameras as a list.
func TestTheContractReadsIntoTheIR(t *testing.T) {
	ir, err := Load("../openapi.json", "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	services := map[string]map[string]*Method{}
	for _, service := range ir.Services {
		services[service.Name] = map[string]*Method{}
		for _, method := range service.Methods {
			services[service.Name][method.Name] = method
		}
	}
	recognize := services["photos"]["recognize"]
	if recognize == nil || !recognize.Multipart || recognize.Kind != KindObject || recognize.Response != "RecognizeResult" || recognize.Path != "/api/v1/recognize" || recognize.HTTPMethod != "POST" {
		t.Fatalf("photos.recognize = %+v", recognize)
	}
	if recognize.Body == nil || recognize.Body.Name != "PhotosRecognizeParams" || !recognize.Body.Input {
		t.Fatalf("photos.recognize body = %+v", recognize.Body)
	}
	fields := map[string]*Field{}
	for _, field := range recognize.Body.Fields {
		fields[field.Wire] = field
	}
	if fields["image"] == nil || fields["image"].Type.Kind != "binary" || !fields["image"].Required || fields["lpr_confidence"] == nil || fields["lpr_confidence"].Required {
		t.Fatalf("photos.recognize fields = %+v", fields)
	}
	if ocr := services["photos"]["ocr"]; ocr == nil || ocr.Response != "OcrResult" {
		t.Fatalf("photos.ocr = %+v", ocr)
	}
	list := services["recognitions"]["list"]
	if list == nil || !list.Paginated || list.Kind != KindPage || list.Item != "Recognition" || list.Cursor != "before" || list.Next != "next" || list.HTTPMethod != "GET" {
		t.Fatalf("recognitions.list = %+v", list)
	}
	if len(list.Query) != 3 {
		t.Fatalf("recognitions.list filters (the cursor is not one) = %+v", list.Query)
	}
	cameras := services["cameras"]["list"]
	if cameras == nil || cameras.Kind != KindList || !cameras.List || cameras.Item != "Camera" || cameras.Paginated {
		t.Fatalf("cameras.list = %+v", cameras)
	}
	image := services["detections"]["image"]
	if image == nil || len(image.PathParams) != 1 || image.PathParams[0] != "id" || image.Response != "DetectionImage" {
		t.Fatalf("detections.image = %+v", image)
	}
	models := map[string]*Model{}
	for _, model := range ir.Models {
		models[model.Name] = model
	}
	for _, name := range []string{"Camera", "Recognition", "RecognizeResult", "RecognizedPlate", "ReadingArea", "RecognitionCreated", "AlertTriggered", "WebhookTest"} {
		if models[name] == nil {
			t.Fatalf("model %s missing", name)
		}
	}
	if models["Error"] != nil || models["CameraList"] != nil || models["RecognitionList"] != nil {
		t.Fatal("the error body or a list wrapper became a model")
	}
	for _, field := range models["Camera"].Fields {
		if field.Wire == "readingArea" && (field.Type.Kind != "model" || field.Type.Model != "ReadingArea") {
			t.Fatalf("Camera.readingArea = %+v", field.Type)
		}
	}
	if Pascal("payment_methods") != "PaymentMethods" || Camel("payment_methods") != "paymentMethods" || Pascal("detectionId") != "DetectionID" ||
		Camel("detectionId") != "detectionID" || Pascal("lpr_confidence") != "LPRConfidence" || Camel("ocr") != "ocr" || Pascal("imageUrl") != "ImageURL" {
		t.Fatal("naming")
	}
}

// A contract whose operations carry no service:method operationId is named by
// the route the documentation generator writes, then by its path.
func TestAnOperationWithoutAnOperationIDIsNamedByItsRoute(t *testing.T) {
	ir, err := load(t, func(doc map[string]any) {
		for _, item := range dig(doc, "paths") {
			for _, op := range item.(map[string]any) {
				delete(op.(map[string]any), "operationId")
			}
		}
		dig(doc, "paths", "/api/v1/recognize", "post")["x-arandu-route-name"] = "api.nothing"
	})
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	for _, service := range ir.Services {
		for _, method := range service.Methods {
			found[service.Name+":"+method.Name] = true
		}
	}
	for _, want := range []string{"recognize:create", "photos:detect", "photos:ocr", "recognitions:list", "cameras:list", "detections:image"} {
		if !found[want] {
			t.Errorf("%s is missing from %v", want, found)
		}
	}
}

// The webhooks section reads into one group a payload, every event in
// exactly one.
func TestTheWebhooksReadIntoGroups(t *testing.T) {
	ir, err := Load("../openapi.json", "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	groups := map[string]*WebhookGroup{}
	seen := map[string]bool{}
	for _, group := range ir.Webhooks {
		groups[group.Name] = group
		for _, kind := range group.Types {
			if seen[kind] {
				t.Fatalf("%s is in two groups", kind)
			}
			seen[kind] = true
		}
	}
	for _, event := range []string{"recognition.created", "alert.triggered", "webhook.test"} {
		if !seen[event] {
			t.Errorf("%s is not a webhook event", event)
		}
	}
	if created := groups["RecognitionCreated"]; created == nil || created.Model != "RecognitionCreated" || !contains(created.Types, "recognition.created") {
		t.Fatalf("RecognitionCreated group = %+v", created)
	}
	if ir.WebhookField != "event" {
		t.Fatalf("webhook field = %q", ir.WebhookField)
	}
}

func contains(values []string, value string) bool {
	for _, each := range values {
		if each == value {
			return true
		}
	}
	return false
}
