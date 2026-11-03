use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use alpr::{
    verify_webhook_at, verify_webhook_signature_at, BoxError, Client, Error, HttpRequest,
    HttpResponse, PhotosDetectParams, PhotosOCRParams, PhotosRecognizeParams,
    RecognitionCreatedSource, RecognitionSource, RecognitionsListParams, WebhookError,
    WebhookEvent,
};
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;

const KEY: &str = "alpr_live_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

type Seen = Arc<Mutex<Vec<HttpRequest>>>;

/// A client whose transport answers with `answer` and records the requests.
fn client(answer: impl Fn(&HttpRequest) -> HttpResponse + Send + Sync + 'static) -> (Client, Seen) {
    let seen: Seen = Arc::default();
    let record = Arc::clone(&seen);
    let transport = move |request: HttpRequest| -> Result<HttpResponse, BoxError> {
        let response = answer(&request);
        record.lock().unwrap().push(request);
        Ok(response)
    };
    let client = Client::builder(KEY)
        .base_url("https://alpr.test/")
        .transport(transport)
        .build();
    (client, seen)
}

fn json(status: u16, body: serde_json::Value) -> HttpResponse {
    HttpResponse::new(status, body.to_string()).with_header("Content-Type", "application/json")
}

/// The value of a query parameter of `url`, or None when it is not there.
fn query(url: &str, name: &str) -> Option<String> {
    let (_, query) = url.split_once('?')?;
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == name).then(|| value.to_owned())
    })
}

// jpeg and png start with the bytes the API tells them by.
const JPEG: &[u8] = &[
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F', 0x00, 0x01,
];
const PNG: &[u8] = &[
    0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, b'I', b'H', b'D', b'R',
];

struct FormPart {
    name: String,
    filename: Option<String>,
    content_type: Option<String>,
    data: Vec<u8>,
}

fn split<'a>(haystack: &'a [u8], needle: &[u8]) -> Vec<&'a [u8]> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut at = 0;
    while at + needle.len() <= haystack.len() {
        if &haystack[at..at + needle.len()] == needle {
            out.push(&haystack[start..at]);
            at += needle.len();
            start = at;
        } else {
            at += 1;
        }
    }
    out.push(&haystack[start..]);
    out
}

/// Reads the multipart body of a request the way a server does.
fn form_parts(content_type: &str, body: &[u8]) -> Vec<FormPart> {
    let boundary = content_type
        .strip_prefix("multipart/form-data; boundary=")
        .expect("a multipart content type with a boundary");
    let delimiter = format!("--{boundary}");
    let pieces = split(body, delimiter.as_bytes());
    assert_eq!(pieces.first().map(|piece| piece.len()), Some(0));
    assert_eq!(pieces.last().copied(), Some(&b"--\r\n"[..]));
    let mut parts = Vec::new();
    for piece in &pieces[1..pieces.len() - 1] {
        let piece = piece.strip_prefix(b"\r\n").unwrap();
        let piece = piece.strip_suffix(b"\r\n").unwrap();
        let divide = split(piece, b"\r\n\r\n");
        let head = String::from_utf8(divide[0].to_vec()).unwrap();
        let data = piece[divide[0].len() + 4..].to_vec();
        let (mut name, mut filename, mut kind) = (String::new(), None, None);
        for line in head.split("\r\n") {
            let (header, value) = line.split_once(": ").unwrap();
            if header.eq_ignore_ascii_case("content-disposition") {
                for item in value.split("; ") {
                    if let Some(found) = item.strip_prefix("name=\"") {
                        name = found.trim_end_matches('"').to_owned();
                    } else if let Some(found) = item.strip_prefix("filename=\"") {
                        filename = Some(found.trim_end_matches('"').to_owned());
                    }
                }
            } else if header.eq_ignore_ascii_case("content-type") {
                kind = Some(value.to_owned());
            }
        }
        parts.push(FormPart {
            name,
            filename,
            content_type: kind,
            data,
        });
    }
    parts
}

fn request_parts(request: &HttpRequest) -> Vec<FormPart> {
    form_parts(
        request.header("content-type").unwrap(),
        request.body.as_deref().unwrap(),
    )
}

const RECOGNIZED: &str = r#"{"creditsRemaining":41,"imageHeight":720,"imageWidth":1280,"plates":[{"charConfs":"0.99,0.98,0.97,0.96,0.97,0.96,0.96","conf":97.3,"coordinateBottom":361,"coordinateLeft":120,"coordinateRight":300,"coordinateTop":301,"createdAt":"2026-10-22T12:00:00-03:00","plate":"BRA2E19","plateType":"mercosul","time":"2026-10-22T12:00:00-03:00"}],"processingTimeMs":84}"#;

fn ok(body: &str) -> HttpResponse {
    HttpResponse::new(200, body).with_header("Content-Type", "application/json")
}

#[test]
fn a_call_carries_the_key_and_no_idempotency_key() {
    let (client, seen) = client(|_| {
        ok(
            r#"{"data":[{"createdAt":"2026-10-01T09:00:00-03:00","enabled":true,"id":"cam_1","location":"Portaria","name":"Portão","protocol":"rtsp","readingArea":null},{"createdAt":"2026-10-01T09:00:00-03:00","enabled":false,"id":"cam_2","location":"","name":"Garagem","protocol":"rtsp","readingArea":{"box":{"height":0.5,"width":0.5,"x":0.1,"y":0.2},"points":[[0.1,0.2],[0.6,0.2],[0.6,0.7]]}}]}"#,
        )
    });
    let cameras = client.cameras().list().unwrap();
    assert_eq!(cameras.len(), 2);
    assert_eq!(cameras[0].id, "cam_1");
    assert!(cameras[0].enabled);
    assert_eq!(cameras[0].reading_area, None);
    let area = cameras[1].reading_area.as_ref().unwrap();
    assert_eq!(area.box_.as_ref().unwrap().x, Some(0.1));
    let points = area.points.as_ref().unwrap();
    assert_eq!(points.len(), 3);
    assert_eq!(points[1][0], 0.6);

    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].method, "GET");
    assert_eq!(seen[0].url, "https://alpr.test/api/v1/cameras");
    assert_eq!(
        seen[0].header("authorization"),
        Some(format!("Bearer {KEY}").as_str())
    );
    assert_eq!(
        seen[0].header("user-agent"),
        Some(format!("alpr-rust/{}", alpr::VERSION).as_str())
    );
    assert!(seen[0]
        .header("user-agent")
        .unwrap()
        .starts_with("alpr-rust/"));
    assert_eq!(seen[0].header("accept"), Some("application/json"));
    assert_eq!(seen[0].header("idempotency-key"), None);
    assert_eq!(seen[0].body, None);
}

#[test]
fn a_photo_goes_as_multipart() {
    let (client, seen) = client(|_| ok(RECOGNIZED));
    let result = client
        .photos()
        .recognize(&PhotosRecognizeParams::new(JPEG).lpr_confidence(0.5))
        .unwrap();
    assert_eq!(result.credits_remaining, 41);
    assert_eq!(result.plates.len(), 1);
    assert_eq!(result.plates[0].plate, "BRA2E19");
    assert_eq!(result.plates[0].conf, 97.3);
    assert_eq!(result.plates[0].coordinate_left, 120);

    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].method, "POST");
    assert_eq!(seen[0].url, "https://alpr.test/api/v1/recognize");
    assert!(seen[0]
        .header("content-type")
        .unwrap()
        .starts_with("multipart/form-data; boundary="));
    let parts = request_parts(&seen[0]);
    assert_eq!(parts.len(), 2);
    let image = parts.iter().find(|part| part.name == "image").unwrap();
    assert_eq!(image.data, JPEG);
    assert_eq!(image.filename.as_deref(), Some("photo.jpg"));
    assert_eq!(image.content_type.as_deref(), Some("image/jpeg"));
    let confidence = parts
        .iter()
        .find(|part| part.name == "lpr_confidence")
        .unwrap();
    assert_eq!(confidence.data, b"0.5");
    assert_eq!(confidence.filename, None);
    // An option left out is not sent.
    assert!(parts.iter().all(|part| part.name != "min_ocr_confidence"));
}

#[test]
fn a_photo_is_named_by_its_bytes() {
    let not_an_image: &[u8] = b"not an image";
    for (name, data, filename, kind) in [
        ("jpeg", JPEG, "photo.jpg", "image/jpeg"),
        ("png", PNG, "photo.png", "image/png"),
        ("other", not_an_image, "photo", "application/octet-stream"),
    ] {
        let (client, seen) = client(|_| {
            ok(r#"{"imageHeight":10,"imageWidth":20,"plates":[],"processingTimeMs":3}"#)
        });
        let result = client
            .photos()
            .detect(&PhotosDetectParams::new(data.to_vec()))
            .unwrap();
        assert_eq!(result.image_width, 20, "{name}");
        assert!(result.plates.is_empty(), "{name}");
        let seen = seen.lock().unwrap();
        assert_eq!(seen[0].url, "https://alpr.test/api/v1/detect");
        let parts = request_parts(&seen[0]);
        assert_eq!(parts.len(), 1, "{name}");
        assert_eq!(parts[0].name, "image", "{name}");
        assert_eq!(parts[0].data, data, "{name}");
        assert_eq!(parts[0].filename.as_deref(), Some(filename), "{name}");
        assert_eq!(parts[0].content_type.as_deref(), Some(kind), "{name}");
    }
}

#[test]
fn the_form_options_are_text_parts_in_the_shortest_decimal() {
    let (client, seen) = client(|_| ok(RECOGNIZED));
    client
        .photos()
        .recognize(
            &PhotosRecognizeParams::new(PNG)
                .lpr_confidence(0.25)
                .min_ocr_confidence(1.0),
        )
        .unwrap();
    let seen = seen.lock().unwrap();
    let parts = request_parts(&seen[0]);
    let text = |name: &str| {
        parts
            .iter()
            .find(|part| part.name == name)
            .map(|part| String::from_utf8(part.data.clone()).unwrap())
    };
    assert_eq!(text("lpr_confidence").as_deref(), Some("0.25"));
    assert_eq!(text("min_ocr_confidence").as_deref(), Some("1"));
}

#[test]
fn a_plate_image_is_read_by_ocr() {
    let (client, seen) = client(|_| {
        ok(
            r#"{"confidence":0.91,"creditsRemaining":40,"detectionId":null,"latencyMs":12,"plate":"ABC1234"}"#,
        )
    });
    let result = client.photos().ocr(&PhotosOCRParams::new(PNG)).unwrap();
    assert_eq!(result.plate, "ABC1234");
    assert_eq!(result.detection_id, None);
    assert_eq!(result.confidence, 0.91);
    assert_eq!(seen.lock().unwrap()[0].url, "https://alpr.test/api/v1/ocr");
}

#[test]
fn a_detection_image_is_a_link() {
    let (client, seen) = client(|_| {
        ok(
            r#"{"detectionId":"a/b","expiresIn":300,"imageUrl":"https://alpr.sh/api/v1/detections/a/image/file?s=x"}"#,
        )
    });
    let image = client.detections().image("a/b").unwrap();
    assert_eq!(image.expires_in, 300);
    assert_eq!(image.detection_id, "a/b");
    assert!(image.image_url.starts_with("https://alpr.sh/"));
    assert_eq!(
        seen.lock().unwrap()[0].url,
        "https://alpr.test/api/v1/detections/a%2Fb/image"
    );
}

fn reading(id: &str) -> serde_json::Value {
    serde_json::json!({"cameraId": null, "capturedAt": "2026-10-22T12:00:00-03:00", "conf": 90, "id": id, "plate": "BRA2E19", "source": "api"})
}

#[test]
fn iterating_walks_every_page_by_cursor() {
    let (client, seen) = client(|request| match query(&request.url, "before").as_deref() {
        None => json(
            200,
            serde_json::json!({"data": [reading("r3"), reading("r2")], "next": "c2"}),
        ),
        Some("c2") => json(
            200,
            serde_json::json!({"data": [reading("r1")], "next": null}),
        ),
        Some(other) => panic!("cursor {other}"),
    });
    let ids: Vec<String> = client
        .recognitions()
        .list_iter(RecognitionsListParams::new().plate("BRA").source("api"))
        .map(|reading| reading.unwrap().id)
        .collect();
    assert_eq!(ids, ["r3", "r2", "r1"]);
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        // The cursor is not sent on the first request, and the filters are on both.
        assert_eq!(query(&seen[0].url, "before"), None);
        assert_eq!(query(&seen[1].url, "before").as_deref(), Some("c2"));
        for request in seen.iter() {
            assert!(request
                .url
                .starts_with("https://alpr.test/api/v1/recognitions?"));
            assert_eq!(query(&request.url, "plate").as_deref(), Some("BRA"));
            assert_eq!(query(&request.url, "source").as_deref(), Some("api"));
            assert_eq!(query(&request.url, "camera"), None);
        }
    }

    let page = client
        .recognitions()
        .list(&RecognitionsListParams::new().before("c2"))
        .unwrap();
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.next, None);
    assert_eq!(page.items[0].camera_id, None);
    assert_eq!(page.items[0].source, RecognitionSource::Api);
}

#[test]
fn a_page_is_taken_only_when_its_turn_comes() {
    let (client, seen) = client(|_| {
        json(
            200,
            serde_json::json!({"data": [reading("r1")], "next": "c2"}),
        )
    });
    let mut walk = client
        .recognitions()
        .list_iter(RecognitionsListParams::new());
    assert_eq!(seen.lock().unwrap().len(), 0);
    assert_eq!(walk.next().unwrap().unwrap().id, "r1");
    assert_eq!(seen.lock().unwrap().len(), 1);
}

#[test]
fn a_cursor_that_does_not_move_ends_the_walk() {
    let (client, seen) = client(|_| {
        json(
            200,
            serde_json::json!({"data": [reading("r1")], "next": "same"}),
        )
    });
    let items: Vec<_> = client
        .recognitions()
        .list_iter(RecognitionsListParams::new())
        .collect();
    assert_eq!(items.len(), 2);
    assert!(items.iter().all(Result::is_ok));
    assert_eq!(seen.lock().unwrap().len(), 2);
}

#[test]
fn an_error_ends_the_walk() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&calls);
    let (client, _) = client(move |_| {
        if counted.fetch_add(1, Ordering::SeqCst) == 0 {
            json(
                200,
                serde_json::json!({"data": [reading("r1")], "next": "c2"}),
            )
        } else {
            json(
                503,
                serde_json::json!({"error": "engine_unavailable", "message": "Try later."}),
            )
        }
    });
    let items: Vec<_> = client
        .recognitions()
        .list_iter(RecognitionsListParams::new())
        .collect();
    assert_eq!(items.len(), 2);
    assert!(items[0].is_ok());
    let Err(Error::Api(refused)) = &items[1] else {
        panic!("{:?}", items[1]);
    };
    assert_eq!(refused.status, 503);
    assert_eq!(refused.code, "engine_unavailable");
    assert_eq!(calls.load(Ordering::SeqCst), 2);
}

#[test]
fn a_refusal_is_a_typed_error() {
    let (client, _) = client(|request| {
        if request.url.ends_with("/api/v1/recognize") {
            json(
                402,
                serde_json::json!({"error": "insufficient_credits", "message": "This workspace has no credits left."}),
            )
        } else {
            json(
                429,
                serde_json::json!({"error": "rate_limited", "message": "Too many requests."}),
            )
            .with_header("Retry-After", "7")
        }
    });
    let Err(Error::Api(refused)) = client.photos().recognize(&PhotosRecognizeParams::new(JPEG))
    else {
        panic!("a 402 was not refused");
    };
    assert_eq!(refused.status, 402);
    assert_eq!(refused.code, "insufficient_credits");
    assert_eq!(refused.message, "This workspace has no credits left.");
    assert_eq!(refused.retry_after, None);
    assert!(refused.fields.is_empty());

    let Err(error) = client.cameras().list() else {
        panic!("a 429 was not refused");
    };
    let refused = error.api().unwrap();
    assert_eq!(refused.status, 429);
    assert_eq!(refused.code, "rate_limited");
    assert_eq!(refused.retry_after, Some(Duration::from_secs(7)));
    assert!(error.to_string().contains("rate_limited"));
}

#[test]
fn an_error_body_that_is_not_json_is_still_an_error() {
    let (client, _) = client(|_| HttpResponse::new(502, "<html>bad gateway</html>"));
    let Err(Error::Api(refused)) = client.cameras().list() else {
        panic!("a 502 was not refused");
    };
    assert_eq!(refused.status, 502);
    assert_eq!(refused.code, "");
    assert!(refused.fields.is_empty());
}

#[test]
fn a_call_can_use_another_key() {
    let (client, seen) = client(|_| ok(r#"{"data":[]}"#));
    client.cameras().api_key("alpr_live_other").list().unwrap();
    client.cameras().list().unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(
        seen[0].header("authorization"),
        Some("Bearer alpr_live_other")
    );
    assert_eq!(
        seen[1].header("authorization"),
        Some(format!("Bearer {KEY}").as_str())
    );
}

#[test]
fn a_base_url_must_be_https_unless_it_is_loopback() {
    let calls = Arc::new(AtomicUsize::new(0));
    for (base, accepted) in [
        ("https://alpr.sh", true),
        ("http://localhost:8080", true),
        ("http://LOCALHOST", true),
        ("http://127.0.0.1:1", true),
        ("http://127.255.0.3", true),
        ("http://[::1]:8080", true),
        ("http://alpr.sh", false),
        ("http://localhost.evil.test", false),
        ("http://127.0.0.1.evil.test", false),
        ("http://10.0.0.1", false),
        ("ftp://localhost", false),
        ("alpr.sh", false),
        ("", false),
        ("http://[::2]", false),
    ] {
        let counted = Arc::clone(&calls);
        let client = Client::builder("k")
            .base_url(base)
            .transport(move |_: HttpRequest| -> Result<HttpResponse, BoxError> {
                counted.fetch_add(1, Ordering::SeqCst);
                Ok(ok(r#"{"data":[]}"#))
            })
            .build();
        let answer = client.cameras().list();
        assert_eq!(
            !matches!(answer, Err(Error::InsecureBaseUrl)),
            accepted,
            "{base}"
        );
    }
    // Only the accepted ones sent anything.
    assert_eq!(calls.load(Ordering::SeqCst), 6);
}

/// What a server through real HTTP saw of one request.
#[derive(Default, Clone)]
struct Received {
    request_line: String,
    content_type: String,
    authorization: String,
    body: Vec<u8>,
}

/// Answers every request with `response`, keeps the last one it read and
/// counts the connections it gets.
fn canned_server(response: String) -> (String, Arc<AtomicUsize>, Arc<Mutex<Received>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let hits = Arc::new(AtomicUsize::new(0));
    let last = Arc::new(Mutex::new(Received::default()));
    let (count, keep) = (Arc::clone(&hits), Arc::clone(&last));
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            count.fetch_add(1, Ordering::SeqCst);
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut received = Received::default();
            reader.read_line(&mut received.request_line).unwrap();
            let mut length = 0;
            loop {
                let mut header = String::new();
                if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim_end().is_empty() {
                    break;
                }
                if let Some((name, value)) = header.trim_end().split_once(':') {
                    match name.to_ascii_lowercase().as_str() {
                        "content-length" => length = value.trim().parse().unwrap_or(0),
                        "content-type" => received.content_type = value.trim().to_owned(),
                        "authorization" => received.authorization = value.trim().to_owned(),
                        _ => {}
                    }
                }
            }
            received.body = vec![0; length];
            reader.read_exact(&mut received.body).unwrap();
            *keep.lock().unwrap() = received;
            let _ = stream.write_all(response.as_bytes());
        }
    });
    (format!("http://{address}"), hits, last)
}

#[test]
fn the_real_http_sends_the_multipart_through_ureq() {
    let body = RECOGNIZED;
    let (base_url, _, last) = canned_server(format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    ));
    let client = Client::builder(KEY).base_url(&base_url).build();
    let result = client
        .photos()
        .recognize(&PhotosRecognizeParams::new(JPEG).min_ocr_confidence(0.7))
        .unwrap();
    assert_eq!(result.plates[0].plate, "BRA2E19");
    let received = last.lock().unwrap().clone();
    assert!(received.request_line.starts_with("POST /api/v1/recognize "));
    assert_eq!(received.authorization, format!("Bearer {KEY}"));
    let parts = form_parts(&received.content_type, &received.body);
    assert_eq!(parts[0].name, "image");
    assert_eq!(parts[0].data, JPEG);
    assert_eq!(parts[1].name, "min_ocr_confidence");
    assert_eq!(parts[1].data, b"0.7");
}

#[test]
fn the_real_http_reads_a_refusal() {
    let body = r#"{"error":"rate_limited","message":"Too many requests."}"#;
    let (base_url, _, _) = canned_server(format!(
        "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nRetry-After: 7\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    ));
    let client = Client::builder(KEY).base_url(&base_url).build();
    let Err(Error::Api(refused)) = client.cameras().list() else {
        panic!("a 429 was not refused");
    };
    assert_eq!(refused.status, 429);
    assert_eq!(refused.code, "rate_limited");
    assert_eq!(refused.retry_after, Some(Duration::from_secs(7)));
}

#[test]
fn a_redirect_is_refused_and_the_key_never_follows_it() {
    let (elsewhere, hits, _) = canned_server(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".to_owned(),
    );
    let (first, _, _) = canned_server(format!(
        "HTTP/1.1 302 Found\r\nLocation: {elsewhere}/steal\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    ));
    let client = Client::builder(KEY).base_url(&first).build();
    let Err(Error::Api(refused)) = client.cameras().list() else {
        panic!("a redirect was followed");
    };
    assert_eq!(refused.status, 302);
    assert_eq!(hits.load(Ordering::SeqCst), 0);
}

// The webhook vectors every SDK checks (generator/testdata/webhook-vectors.json):
// Alpr.sh events signed under two secrets, as while one is rotated.
const NEW_SECRET: &str = "whsec_SDK-test-secret-new-0123456789";
const OLD_SECRET: &str = "whsec_SDK-test-secret-old-0123456789";
const OTHER_SECRET: &str = "whsec_SDK-test-secret-other-012345678";
const SIGNED_AT: u64 = 1792670400;

const RECOGNITION_BODY: &str = r#"{"event":"recognition.created","id":"rec_1","tenant_id":"ws_1","source":"camera","camera_id":"cam_1","plate":"BRA2E19","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}"#;
const RECOGNITION_NEW: &str =
    "sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623";
const RECOGNITION_OLD: &str =
    "sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781";
const ALERT_BODY: &str = r#"{"event":"alert.triggered","id":"alt_1","tenant_id":"ws_1","rule_id":"rule_1","rule_name":"Veículo bloqueado","recognition_id":"rec_1","plate":"BRA2E19","camera_id":"cam_1","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}"#;
const ALERT_NEW: &str = "sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a";
const TEST_BODY: &str =
    r#"{"event":"webhook.test","id":"evt_1","tenant_id":"ws_1","sent_at":"2026-10-22T12:00:00Z"}"#;
const TEST_NEW: &str = "sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245";
const UNKNOWN_BODY: &str = r#"{"event":"payout.sent","id":"po_1","tenant_id":"ws_1"}"#;
const UNKNOWN_NEW: &str = "sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6";
const PLUS_SIGNATURE: &str =
    "sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771";

type Headers = Vec<(String, String)>;

fn webhook_headers(id: &str, stamp: &str, signatures: &[&str]) -> Headers {
    let mut headers = vec![
        ("x-alprsh-delivery-id".to_owned(), id.to_owned()),
        ("X-Alprsh-Timestamp".to_owned(), stamp.to_owned()),
    ];
    for signature in signatures {
        headers.push(("X-Alprsh-Signature".to_owned(), (*signature).to_owned()));
    }
    headers
}

fn at(seconds: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(seconds)
}

fn now() -> SystemTime {
    at(SIGNED_AT + 120)
}

fn invalid_signature(answer: Result<(), WebhookError>) -> bool {
    matches!(answer, Err(WebhookError::InvalidSignature))
}

#[test]
fn the_webhook_vector_verifies() {
    let body = RECOGNITION_BODY.as_bytes();
    let stamp = SIGNED_AT.to_string();
    let header = webhook_headers("del_0001", &stamp, &[RECOGNITION_NEW]);
    let check = |secret: &str, headers: Headers, body: &[u8], when: SystemTime| {
        verify_webhook_signature_at(secret, headers, body, when)
    };
    check(NEW_SECRET, header.clone(), body, now()).unwrap();
    let mut changed = body.to_vec();
    changed.push(b' ');
    assert!(
        invalid_signature(check(NEW_SECRET, header.clone(), &changed, now())),
        "a changed body verified"
    );
    assert!(
        invalid_signature(check(
            NEW_SECRET,
            webhook_headers("del_0009", &stamp, &[RECOGNITION_NEW]),
            body,
            now()
        )),
        "another delivery id verified"
    );
    assert!(
        invalid_signature(check(NEW_SECRET, header.clone(), body, at(SIGNED_AT + 301))),
        "a stale webhook verified"
    );
    assert!(
        invalid_signature(check(NEW_SECRET, header.clone(), body, at(SIGNED_AT - 301))),
        "a webhook from the future verified"
    );
    check(NEW_SECRET, header.clone(), body, at(SIGNED_AT + 300))
        .expect("a webhook at the edge of the tolerance was refused");
    assert!(
        invalid_signature(check(OTHER_SECRET, header.clone(), body, now())),
        "another secret verified"
    );
    assert!(
        matches!(
            check("", header.clone(), body, now()),
            Err(WebhookError::EmptySecret)
        ),
        "an empty secret must be a configuration error"
    );
    assert!(
        invalid_signature(check(NEW_SECRET, Vec::new(), body, now())),
        "a request with no headers verified"
    );
    assert!(invalid_signature(check(
        NEW_SECRET,
        webhook_headers("", &stamp, &[RECOGNITION_NEW]),
        body,
        now()
    )));
    // The headers can be a map, too.
    let map: std::collections::HashMap<String, String> = header.into_iter().collect();
    verify_webhook_signature_at(NEW_SECRET, &map, body, now()).unwrap();
}

#[test]
fn a_timestamp_that_is_not_plain_digits_is_refused() {
    let body = RECOGNITION_BODY.as_bytes();
    for stamp in ["+1792670400", "²", "", "1_7", " 1792670400", "1792670400 "] {
        let headers = webhook_headers("del_0001", stamp, &[PLUS_SIGNATURE]);
        assert!(
            invalid_signature(verify_webhook_signature_at(
                NEW_SECRET,
                headers,
                body,
                now()
            )),
            "{stamp:?} verified"
        );
    }
    let no_stamp = vec![
        ("X-Alprsh-Delivery-Id".to_owned(), "del_0001".to_owned()),
        ("X-Alprsh-Signature".to_owned(), RECOGNITION_NEW.to_owned()),
    ];
    assert!(invalid_signature(verify_webhook_signature_at(
        NEW_SECRET,
        no_stamp,
        body,
        now()
    )));
}

#[test]
fn more_than_one_signature_verifies_during_a_rotation() {
    let body = RECOGNITION_BODY.as_bytes();
    let stamp = SIGNED_AT.to_string();
    let one_value = format!("{RECOGNITION_OLD},{RECOGNITION_NEW}");
    let with_spaces = format!("{RECOGNITION_OLD}, {RECOGNITION_NEW}");
    let rotations = [
        (
            "one value",
            webhook_headers("del_0001", &stamp, &[&one_value]),
        ),
        (
            "two lines",
            webhook_headers("del_0001", &stamp, &[RECOGNITION_OLD, RECOGNITION_NEW]),
        ),
        (
            "with spaces",
            webhook_headers("del_0001", &stamp, &[&with_spaces]),
        ),
    ];
    for (name, headers) in rotations {
        for secret in [NEW_SECRET, OLD_SECRET] {
            verify_webhook_signature_at(secret, headers.clone(), body, now())
                .unwrap_or_else(|error| panic!("{name} under {secret}: {error}"));
        }
        assert!(
            invalid_signature(verify_webhook_signature_at(
                OTHER_SECRET,
                headers.clone(),
                body,
                now()
            )),
            "{name}: a secret that signed nothing verified"
        );
    }
    let bare = RECOGNITION_NEW.trim_start_matches("sha256=");
    let beside_a_good_one = format!("sha256=zz,{RECOGNITION_NEW}");
    let too_many = format!(
        "{}{RECOGNITION_NEW}",
        format!("{RECOGNITION_OLD},").repeat(6)
    );
    for (name, signature) in [
        (
            "a malformed one beside a good one",
            beside_a_good_one.as_str(),
        ),
        ("no prefix", bare),
        ("a short one", "sha256=97de"),
        ("too many", too_many.as_str()),
        ("empty", ""),
    ] {
        let headers = webhook_headers("del_0001", &stamp, &[signature]);
        assert!(
            invalid_signature(verify_webhook_signature_at(
                NEW_SECRET,
                headers,
                body,
                now()
            )),
            "{name} verified"
        );
    }
}

#[test]
fn a_webhook_answers_its_typed_event() {
    let stamp = SIGNED_AT.to_string();
    let event = verify_webhook_at(
        NEW_SECRET,
        webhook_headers("del_0001", &stamp, &[RECOGNITION_NEW]),
        RECOGNITION_BODY.as_bytes(),
        now(),
    )
    .unwrap();
    assert_eq!(event.event_name(), "recognition.created");
    assert_eq!(event.id(), "rec_1");
    let WebhookEvent::RecognitionCreated(read) = event else {
        panic!("{event:?}");
    };
    assert_eq!(read.id, "rec_1");
    assert_eq!(read.plate, "BRA2E19");
    assert_eq!(read.confidence, 0.97);
    assert_eq!(read.camera_id.as_deref(), Some("cam_1"));
    assert_eq!(read.source, RecognitionCreatedSource::Camera);
    assert_eq!(read.tenant_id, "ws_1");
    assert_eq!(read.captured_at, "2026-10-22T11:59:58Z");

    let event = verify_webhook_at(
        NEW_SECRET,
        webhook_headers("del_0002", &stamp, &[ALERT_NEW]),
        ALERT_BODY.as_bytes(),
        now(),
    )
    .unwrap();
    let WebhookEvent::AlertTriggered(alert) = event else {
        panic!("{event:?}");
    };
    assert_eq!(alert.rule_name, "Veículo bloqueado");
    assert_eq!(alert.recognition_id, "rec_1");
    assert_eq!(alert.rule_id, "rule_1");

    let event = verify_webhook_at(
        NEW_SECRET,
        webhook_headers("del_0003", &stamp, &[TEST_NEW]),
        TEST_BODY.as_bytes(),
        now(),
    )
    .unwrap();
    assert_eq!(event.event_name(), "webhook.test");
    let WebhookEvent::WebhookTest(test) = event else {
        panic!("{event:?}");
    };
    assert_eq!(test.sent_at, "2026-10-22T12:00:00Z");

    let event = verify_webhook_at(
        NEW_SECRET,
        webhook_headers("del_0004", &stamp, &[UNKNOWN_NEW]),
        UNKNOWN_BODY.as_bytes(),
        now(),
    )
    .unwrap();
    assert_eq!(event.event_name(), "payout.sent");
    let WebhookEvent::Unknown(unknown) = event else {
        panic!("{event:?}");
    };
    assert_eq!(unknown.event, "payout.sent");
    assert_eq!(unknown.id, "po_1");
    assert_eq!(
        unknown.body,
        serde_json::from_str::<serde_json::Value>(UNKNOWN_BODY).unwrap()
    );

    // A body signed with nothing is refused before it is read.
    let zeros = format!("sha256={}", "0".repeat(64));
    assert!(matches!(
        verify_webhook_at(
            NEW_SECRET,
            webhook_headers("del_0005", &stamp, &[&zeros]),
            br#"{"id":"x"}"#,
            now()
        ),
        Err(WebhookError::InvalidSignature)
    ));
}

/// The signature the server would send for `body`.
fn sign(secret: &str, id: &str, stamp: &str, body: &[u8]) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
    mac.update(format!("{stamp}.{id}.").as_bytes());
    mac.update(body);
    let hex: String = mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    format!("sha256={hex}")
}

#[test]
fn a_verified_body_that_is_not_an_event_is_a_parse_error() {
    let stamp = SIGNED_AT.to_string();
    for body in [&br#"[1]"#[..], br#"{"id":"x"}"#, br#"{"event":7}"#, b"nope"] {
        let signature = sign(NEW_SECRET, "del_0001", &stamp, body);
        let answer = verify_webhook_at(
            NEW_SECRET,
            webhook_headers("del_0001", &stamp, &[&signature]),
            body,
            now(),
        );
        assert!(
            matches!(answer, Err(WebhookError::InvalidPayload(_))),
            "{}",
            String::from_utf8_lossy(body)
        );
    }
    // The same helper signs what the vectors hold.
    assert_eq!(
        sign(NEW_SECRET, "del_0001", &stamp, RECOGNITION_BODY.as_bytes()),
        RECOGNITION_NEW
    );
}
