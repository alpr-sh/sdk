package alpr

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const key = "alpr_live_" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func server(t *testing.T, handle func(w http.ResponseWriter, r *http.Request)) *Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(handle))
	t.Cleanup(srv.Close)
	return New(key, WithBaseURL(srv.URL))
}

// jpeg and png start with the bytes the API tells them by.
var (
	jpeg = []byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00, 0x01}
	png  = []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 'I', 'H', 'D', 'R'}
)

const recognized = `{"creditsRemaining":41,"imageHeight":720,"imageWidth":1280,"plates":[{"charConfs":"0.99,0.98,0.97,0.96,0.97,0.96,0.96","conf":97.3,"coordinateBottom":361,"coordinateLeft":120,"coordinateRight":300,"coordinateTop":301,"createdAt":"2026-10-22T12:00:00-03:00","plate":"BRA2E19","plateType":"mercosul","time":"2026-10-22T12:00:00-03:00"}],"processingTimeMs":84}`

func TestACallCarriesTheKeyAndNoIdempotencyKey(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+key || r.URL.Path != "/api/v1/cameras" || r.Method != http.MethodGet {
			t.Errorf("request %s %s %q", r.Method, r.URL.Path, r.Header.Get("Authorization"))
		}
		if !strings.HasPrefix(r.Header.Get("User-Agent"), "alpr-go/") || r.Header.Get("Accept") != "application/json" {
			t.Errorf("headers %v", r.Header)
		}
		if r.Header.Get("Idempotency-Key") != "" {
			t.Error("the API does not take an Idempotency-Key")
		}
		fmt.Fprint(w, `{"data":[{"createdAt":"2026-10-01T09:00:00-03:00","enabled":true,"id":"cam_1","location":"Portaria","name":"Portão","protocol":"rtsp","readingArea":null},{"createdAt":"2026-10-01T09:00:00-03:00","enabled":false,"id":"cam_2","location":"","name":"Garagem","protocol":"rtsp","readingArea":{"box":{"height":0.5,"width":0.5,"x":0.1,"y":0.2},"points":[[0.1,0.2],[0.6,0.2],[0.6,0.7]]}}]}`)
	})
	cameras, err := client.Cameras.List(context.Background())
	if err != nil || len(cameras) != 2 || cameras[0].ID != "cam_1" || !cameras[0].Enabled || cameras[0].ReadingArea != nil {
		t.Fatalf("cameras %+v, %v", cameras, err)
	}
	area := cameras[1].ReadingArea
	if area == nil || area.Box.X != 0.1 || len(area.Points) != 3 || area.Points[1][0] != 0.6 {
		t.Fatalf("reading area %+v", area)
	}
}

func TestAPhotoGoesAsMultipart(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/recognize" || !strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data; boundary=") {
			t.Errorf("request %s %s %q", r.Method, r.URL.Path, r.Header.Get("Content-Type"))
		}
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Fatal(err)
		}
		file, header, err := r.FormFile("image")
		if err != nil {
			t.Fatal(err)
		}
		sent, _ := io.ReadAll(file)
		if string(sent) != string(jpeg) || header.Filename != "photo.jpg" || header.Header.Get("Content-Type") != "image/jpeg" {
			t.Errorf("image %q %q %q", sent, header.Filename, header.Header.Get("Content-Type"))
		}
		if r.FormValue("lpr_confidence") != "0.5" {
			t.Errorf("lpr_confidence %q", r.FormValue("lpr_confidence"))
		}
		if _, sent := r.MultipartForm.Value["min_ocr_confidence"]; sent {
			t.Error("an option left out was sent")
		}
		fmt.Fprint(w, recognized)
	})
	confidence := 0.5
	result, err := client.Photos.Recognize(context.Background(), PhotosRecognizeParams{Image: jpeg, LPRConfidence: &confidence})
	if err != nil || result.CreditsRemaining != 41 || len(result.Plates) != 1 || result.Plates[0].Plate != "BRA2E19" || result.Plates[0].Conf != 97.3 || result.Plates[0].CoordinateLeft != 120 {
		t.Fatalf("result %+v, %v", result, err)
	}
}

func TestAPhotoIsNamedByItsBytes(t *testing.T) {
	for name, tc := range map[string]struct {
		data     []byte
		filename string
		kind     string
	}{"jpeg": {jpeg, "photo.jpg", "image/jpeg"}, "png": {png, "photo.png", "image/png"}, "other": {[]byte("not an image"), "photo", "application/octet-stream"}} {
		client := server(t, func(w http.ResponseWriter, r *http.Request) {
			if err := r.ParseMultipartForm(1 << 20); err != nil {
				t.Fatal(err)
			}
			_, header, err := r.FormFile("image")
			if err != nil || header.Filename != tc.filename || header.Header.Get("Content-Type") != tc.kind {
				t.Errorf("%s: %v %q %q", name, err, header.Filename, header.Header.Get("Content-Type"))
			}
			fmt.Fprint(w, `{"imageHeight":10,"imageWidth":20,"plates":[],"processingTimeMs":3}`)
		})
		result, err := client.Photos.Detect(context.Background(), PhotosDetectParams{Image: tc.data})
		if err != nil || result.ImageWidth != 20 || len(result.Plates) != 0 {
			t.Fatalf("%s: %+v, %v", name, result, err)
		}
	}
}

func TestAPlateImageIsReadByOCR(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/ocr" {
			t.Errorf("path %s", r.URL.Path)
		}
		fmt.Fprint(w, `{"confidence":0.91,"creditsRemaining":40,"detectionId":null,"latencyMs":12,"plate":"ABC1234"}`)
	})
	result, err := client.Photos.OCR(context.Background(), PhotosOCRParams{Image: png})
	if err != nil || result.Plate != "ABC1234" || result.DetectionID != nil || result.Confidence != 0.91 {
		t.Fatalf("result %+v, %v", result, err)
	}
}

func TestADetectionImageIsALink(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.EscapedPath() != "/api/v1/detections/a%2Fb/image" {
			t.Errorf("path %s", r.URL.EscapedPath())
		}
		fmt.Fprint(w, `{"detectionId":"a/b","expiresIn":300,"imageUrl":"https://alpr.sh/api/v1/detections/a/image/file?s=x"}`)
	})
	image, err := client.Recognitions.Image(context.Background(), "a/b")
	if err != nil || image.ExpiresIn != 300 || image.DetectionID != "a/b" || !strings.HasPrefix(image.ImageURL, "https://alpr.sh/") {
		t.Fatalf("image %+v, %v", image, err)
	}
}

func TestIteratingWalksEveryPageByCursor(t *testing.T) {
	var asked []string
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		asked = append(asked, q.Get("before")+"|"+q.Get("plate")+"|"+q.Get("source"))
		item := func(id string) string {
			return fmt.Sprintf(`{"cameraId":null,"capturedAt":"2026-10-22T12:00:00-03:00","conf":90,"id":%q,"plate":"BRA2E19","source":"api"}`, id)
		}
		switch q.Get("before") {
		case "":
			fmt.Fprintf(w, `{"data":[%s,%s],"next":"c2"}`, item("r3"), item("r2"))
		case "c2":
			fmt.Fprintf(w, `{"data":[%s],"next":null}`, item("r1"))
		default:
			t.Errorf("cursor %q", q.Get("before"))
		}
	})
	var ids []string
	for reading, err := range client.Recognitions.ListIter(context.Background(), &RecognitionsListParams{Plate: "BRA", Source: "api"}) {
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, reading.ID)
	}
	if fmt.Sprint(ids) != "[r3 r2 r1]" || fmt.Sprint(asked) != "[|BRA|api c2|BRA|api]" {
		t.Fatalf("walked %v, asked %v", ids, asked)
	}
	page, err := client.Recognitions.List(context.Background(), &RecognitionsListParams{Before: "c2"})
	if err != nil || len(page.Items) != 1 || page.Next != "" || page.Items[0].CameraID != nil {
		t.Fatalf("page %+v, %v", page, err)
	}
}

func TestACursorThatDoesNotMoveEndsTheWalk(t *testing.T) {
	calls := 0
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		fmt.Fprint(w, `{"data":[{"cameraId":"cam_1","capturedAt":"2026-10-22T12:00:00-03:00","conf":90,"id":"r1","plate":"ABC1234","source":"camera"}],"next":"same"}`)
	})
	n := 0
	for _, err := range client.Recognitions.ListIter(context.Background(), nil) {
		if err != nil {
			t.Fatal(err)
		}
		n++
	}
	if n != 2 || calls != 2 {
		t.Fatalf("items %d, calls %d", n, calls)
	}
}

func TestARefusalIsATypedError(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/recognize" {
			w.WriteHeader(http.StatusPaymentRequired)
			fmt.Fprint(w, `{"error":"insufficient_credits","message":"This workspace has no credits left."}`)
			return
		}
		w.Header().Set("Retry-After", "7")
		w.WriteHeader(http.StatusTooManyRequests)
		fmt.Fprint(w, `{"error":"rate_limited","message":"Too many requests."}`)
	})
	_, err := client.Photos.Recognize(context.Background(), PhotosRecognizeParams{Image: jpeg})
	var refused *Error
	if !errors.As(err, &refused) || refused.StatusCode != 402 || refused.Code != "insufficient_credits" || refused.Message != "This workspace has no credits left." {
		t.Fatalf("error %#v", err)
	}
	_, err = client.Cameras.List(context.Background())
	if !errors.As(err, &refused) || refused.StatusCode != 429 || refused.Code != "rate_limited" || refused.RetryAfter != 7*time.Second {
		t.Fatalf("error %#v", err)
	}
}

func TestACallCanUseAnotherKey(t *testing.T) {
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer alpr_live_other" {
			t.Errorf("authorization %q", r.Header.Get("Authorization"))
		}
		fmt.Fprint(w, `{"data":[]}`)
	})
	if _, err := client.Cameras.List(context.Background(), WithAPIKey("alpr_live_other")); err != nil {
		t.Fatal(err)
	}
}

func TestARedirectIsRefusedAndTheKeyNeverFollowsIt(t *testing.T) {
	elsewhere := 0
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { elsewhere++ }))
	t.Cleanup(other.Close)
	client := server(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/steal", http.StatusFound)
	})
	_, err := client.Cameras.List(context.Background())
	var refused *Error
	if !errors.As(err, &refused) || refused.StatusCode != http.StatusFound || elsewhere != 0 {
		t.Fatalf("error %#v, the redirect target was called %d times", err, elsewhere)
	}
}

func TestABaseURLMustBeHTTPSUnlessItIsLoopback(t *testing.T) {
	for base, ok := range map[string]bool{
		"https://alpr.sh": true, "http://localhost:8080": true, "http://LOCALHOST": true, "http://127.0.0.1:1": true,
		"http://127.255.0.3": true, "http://[::1]:8080": true,
		"http://alpr.sh": false, "http://localhost.evil.test": false, "http://127.0.0.1.evil.test": false,
		"http://10.0.0.1": false, "ftp://localhost": false, "alpr.sh": false, "": false, "http://[::2]": false,
	} {
		if got := checkBaseURL(base) == nil; got != ok {
			t.Errorf("%q accepted: %v, want %v", base, got, ok)
		}
	}
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true }))
	t.Cleanup(srv.Close)
	client := New(key, WithBaseURL("http://alpr.test"))
	if _, err := client.Cameras.List(context.Background()); !errors.Is(err, ErrInsecureBaseURL) || called {
		t.Fatalf("error %v, called %v", err, called)
	}
}

// The webhook vectors every SDK checks (generator/testdata/webhook-vectors.json):
// Alpr.sh events signed under two secrets, as while one is rotated.
const (
	newSecret   = "whsec_SDK-test-secret-new-0123456789"
	oldSecret   = "whsec_SDK-test-secret-old-0123456789"
	otherSecret = "whsec_SDK-test-secret-other-012345678"
	signedAt    = "1792670400"

	recognitionBody = `{"event":"recognition.created","id":"rec_1","tenant_id":"ws_1","source":"camera","camera_id":"cam_1","plate":"BRA2E19","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}`
	recognitionNew  = "sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623"
	recognitionOld  = "sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781"
	alertBody       = `{"event":"alert.triggered","id":"alt_1","tenant_id":"ws_1","rule_id":"rule_1","rule_name":"Veículo bloqueado","recognition_id":"rec_1","plate":"BRA2E19","camera_id":"cam_1","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}`
	alertNew        = "sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a"
	testBody        = `{"event":"webhook.test","id":"evt_1","tenant_id":"ws_1","sent_at":"2026-10-22T12:00:00Z"}`
	testNew         = "sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245"
	unknownBody     = `{"event":"payout.sent","id":"po_1","tenant_id":"ws_1"}`
	unknownNew      = "sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6"
	plusSignature   = "sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771"
)

func webhookHeader(id, stamp string, signatures ...string) http.Header {
	h := http.Header{}
	h.Set("x-alprsh-delivery-id", id)
	h.Set("X-Alprsh-Timestamp", stamp)
	for _, signature := range signatures {
		h.Add("X-Alprsh-Signature", signature)
	}
	return h
}

var now = time.Unix(1792670400+120, 0)

func TestTheWebhookVectorVerifies(t *testing.T) {
	body := []byte(recognitionBody)
	header := webhookHeader("del_0001", signedAt, recognitionNew)
	if err := verifyWebhookSignatureAt(newSecret, header, body, now); err != nil {
		t.Fatal(err)
	}
	if err := verifyWebhookSignatureAt(newSecret, header, append(body, ' '), now); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("a changed body verified")
	}
	if err := verifyWebhookSignatureAt(newSecret, webhookHeader("del_0009", signedAt, recognitionNew), body, now); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("another delivery id verified")
	}
	if err := verifyWebhookSignatureAt(newSecret, header, body, time.Unix(1792670400+301, 0)); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("a stale webhook verified")
	}
	if err := verifyWebhookSignatureAt(newSecret, header, body, time.Unix(1792670400-301, 0)); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("a webhook from the future verified")
	}
	if err := verifyWebhookSignatureAt(newSecret, header, body, time.Unix(1792670400+300, 0)); err != nil {
		t.Fatal("a webhook at the edge of the tolerance was refused")
	}
	if err := verifyWebhookSignatureAt(otherSecret, header, body, now); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("another secret verified")
	}
	if err := verifyWebhookSignatureAt("", header, body, now); err == nil || errors.Is(err, ErrWebhookSignature) {
		t.Fatal("an empty secret must be a configuration error")
	}
	if err := verifyWebhookSignatureAt(newSecret, http.Header{}, body, now); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("a request with no headers verified")
	}
}

func TestATimestampThatIsNotPlainDigitsIsRefused(t *testing.T) {
	body := []byte(recognitionBody)
	for _, stamp := range []string{"+1792670400", "²", "", "1_7", " 1792670400", "1792670400 "} {
		if err := verifyWebhookSignatureAt(newSecret, webhookHeader("del_0001", stamp, plusSignature), body, now); !errors.Is(err, ErrWebhookSignature) {
			t.Errorf("%q verified: %v", stamp, err)
		}
	}
}

func TestMoreThanOneSignatureVerifiesDuringARotation(t *testing.T) {
	body := []byte(recognitionBody)
	for name, header := range map[string]http.Header{
		"one value":   webhookHeader("del_0001", signedAt, recognitionOld+","+recognitionNew),
		"two lines":   webhookHeader("del_0001", signedAt, recognitionOld, recognitionNew),
		"with spaces": webhookHeader("del_0001", signedAt, recognitionOld+", "+recognitionNew),
	} {
		for _, secret := range []string{newSecret, oldSecret} {
			if err := verifyWebhookSignatureAt(secret, header, body, now); err != nil {
				t.Errorf("%s under %s: %v", name, secret, err)
			}
		}
		if err := verifyWebhookSignatureAt(otherSecret, header, body, now); !errors.Is(err, ErrWebhookSignature) {
			t.Errorf("%s: a secret that signed nothing verified", name)
		}
	}
	for name, signature := range map[string]string{
		"a malformed one beside a good one": "sha256=zz," + recognitionNew,
		"no prefix":                         strings.TrimPrefix(recognitionNew, "sha256="),
		"a short one":                       "sha256=97de",
		"too many":                          strings.Repeat(recognitionOld+",", 6) + recognitionNew,
	} {
		if err := verifyWebhookSignatureAt(newSecret, webhookHeader("del_0001", signedAt, signature), body, now); !errors.Is(err, ErrWebhookSignature) {
			t.Errorf("%s verified", name)
		}
	}
}

func TestAWebhookAnswersItsTypedEvent(t *testing.T) {
	event, err := verifyWebhookAt(newSecret, webhookHeader("del_0001", signedAt, recognitionNew), []byte(recognitionBody), now)
	read, ok := event.(*RecognitionCreatedWebhookEvent)
	if err != nil || !ok || read.EventName() != "recognition.created" || read.ID != "rec_1" || read.Plate != "BRA2E19" || read.Confidence != 0.97 ||
		read.CameraID != "cam_1" || read.Source != "camera" || read.TenantID != "ws_1" || read.CapturedAt != "2026-10-22T11:59:58Z" {
		t.Fatalf("event %#v, %v", event, err)
	}
	event, err = verifyWebhookAt(newSecret, webhookHeader("del_0002", signedAt, alertNew), []byte(alertBody), now)
	alert, ok := event.(*AlertTriggeredWebhookEvent)
	if err != nil || !ok || alert.RuleName != "Veículo bloqueado" || alert.RecognitionID != "rec_1" || alert.RuleID != "rule_1" {
		t.Fatalf("event %#v, %v", event, err)
	}
	event, err = verifyWebhookAt(newSecret, webhookHeader("del_0003", signedAt, testNew), []byte(testBody), now)
	test, ok := event.(*TestWebhookEvent)
	if err != nil || !ok || test.EventName() != "webhook.test" || test.SentAt != "2026-10-22T12:00:00Z" {
		t.Fatalf("event %#v, %v", event, err)
	}
	event, err = verifyWebhookAt(newSecret, webhookHeader("del_0004", signedAt, unknownNew), []byte(unknownBody), now)
	unknown, ok := event.(*UnknownWebhookEvent)
	if err != nil || !ok || unknown.EventName() != "payout.sent" || unknown.ID != "po_1" || string(unknown.Body) != unknownBody {
		t.Fatalf("event %#v, %v", event, err)
	}
	if _, err := verifyWebhookAt(newSecret, webhookHeader("del_0005", signedAt, "sha256="+strings.Repeat("0", 64)), []byte(`{"id":"x"}`), now); !errors.Is(err, ErrWebhookSignature) {
		t.Fatal("a body signed with nothing verified")
	}
}

func TestAVerifiedBodyThatIsNotAnEventIsRefused(t *testing.T) {
	if _, err := parseWebhookEvent([]byte(`[1]`)); err == nil {
		t.Fatal("a list is not an event")
	}
	if _, err := parseWebhookEvent([]byte(`{"id":"x"}`)); err == nil {
		t.Fatal("a body with no event is not an event")
	}
}
