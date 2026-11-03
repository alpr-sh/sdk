use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, UNIX_EPOCH};

use alpr::{
    verify_webhook_at, verify_webhook_signature_at, BoxError, Client, CustomersCreateParams,
    DiscountsCreateParams, DiscountsCreateParamsDuration, DiscountsCreateParamsType,
    DiscountsListParams, Error, HttpRequest, HttpResponse, ProductStatus, ProductsCreateParams,
    ProductsListParams, WebhookError, WebhookEvent,
};

type Seen = Arc<Mutex<Vec<HttpRequest>>>;

fn client(answer: impl Fn(&HttpRequest) -> HttpResponse + Send + Sync + 'static) -> (Client, Seen) {
    let seen: Seen = Arc::default();
    let record = Arc::clone(&seen);
    let transport = move |request: HttpRequest| -> Result<HttpResponse, BoxError> {
        let response = answer(&request);
        record.lock().unwrap().push(request);
        Ok(response)
    };
    let client = Client::builder("prk_test_key")
        .base_url("https://alpr.test/")
        .transport(transport)
        .build();
    (client, seen)
}

fn product(id: &str) -> serde_json::Value {
    serde_json::json!({"id": id, "name": "Curso", "description": "", "status": "active", "created_at": "2026-10-17T00:00:00Z"})
}

fn json(status: u16, body: serde_json::Value) -> HttpResponse {
    HttpResponse::new(status, body.to_string()).with_header("Content-Type", "application/json")
}

fn query(url: &str, name: &str) -> Option<String> {
    let (_, query) = url.split_once('?')?;
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == name).then(|| value.to_owned())
    })
}

#[test]
fn a_call_carries_the_key_and_unwraps_the_data() {
    let (client, seen) = client(|_| json(200, serde_json::json!({"data": product("prod_1")})));
    let got = client.products().get("prod_1").unwrap();
    assert_eq!(got.id, "prod_1");
    assert_eq!(got.status, ProductStatus::Active);
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].method, "GET");
    assert_eq!(seen[0].url, "https://alpr.test/api/v1/products/prod_1");
    assert_eq!(seen[0].header("authorization"), Some("Bearer prk_test_key"));
    assert_eq!(
        seen[0].header("user-agent"),
        Some(format!("alpr-rust/{}", alpr::VERSION).as_str())
    );
}

#[test]
fn a_write_sends_its_body_and_idempotency_key() {
    let (client, seen) = client(|_| json(201, serde_json::json!({"data": product("prod_1")})));
    let created = client
        .products()
        .idempotency_key("create-1")
        .create(&ProductsCreateParams::new("Curso"))
        .unwrap();
    assert_eq!(created.name, "Curso");
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].method, "POST");
    assert_eq!(seen[0].header("idempotency-key"), Some("create-1"));
    assert_eq!(seen[0].header("content-type"), Some("application/json"));
    let body: serde_json::Value = serde_json::from_slice(seen[0].body.as_deref().unwrap()).unwrap();
    // The optional description, left unset, is not sent.
    assert_eq!(body, serde_json::json!({"name": "Curso"}));
}

#[test]
fn a_base_url_must_be_https_unless_it_is_loopback() {
    let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
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
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(json(200, serde_json::json!({"data": product("prod_1")})))
            })
            .build();
        let answer = client.products().get("prod_1");
        assert_eq!(
            !matches!(answer, Err(Error::InsecureBaseUrl)),
            accepted,
            "{base}"
        );
    }
    // Only the accepted ones sent anything.
    assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 6);
}

#[test]
fn a_discount_goes_through_create_get_list_and_delete() {
    let discount = |id: &str| -> serde_json::Value {
        serde_json::from_str(&r#"{"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}"#.replace("__ID__", id)).unwrap()
    };
    let (client, seen) = client(move |request| {
        if request.method == "POST" {
            return json(201, serde_json::json!({ "data": discount("disc_1") }));
        }
        if request.method == "DELETE" {
            return HttpResponse::new(204, "");
        }
        if request.url.contains("/api/v1/discounts?") {
            let page = query(&request.url, "page").unwrap();
            return json(
                200,
                serde_json::json!({"data": {"items": [discount(&format!("disc_{page}"))], "pagination": {"total_count": 2, "max_page": 2}}}),
            );
        }
        json(200, serde_json::json!({ "data": discount("disc_1") }))
    });
    let created = client
        .discounts()
        .create(
            &DiscountsCreateParams::new(
                DiscountsCreateParamsDuration::Once,
                "Black",
                DiscountsCreateParamsType::Percentage,
            )
            .basis_points(1000),
        )
        .unwrap();
    assert_eq!(created.id, "disc_1");
    assert_eq!(created.code, None);
    assert_eq!(created.product_ids, ["prod_1"]);
    assert_eq!(client.discounts().get("disc_1").unwrap().name, "Black");
    let ids: Vec<String> = client
        .discounts()
        .list_iter(DiscountsListParams::new().limit(1))
        .map(|each| each.unwrap().id)
        .collect();
    assert_eq!(ids, ["disc_1", "disc_2"]);
    // A 204 has no body, and the method answers nothing.
    client.discounts().delete("disc_1").unwrap();
    let seen = seen.lock().unwrap();
    let requests: Vec<String> = seen
        .iter()
        .map(|request| {
            let path = request.url.split('?').next().unwrap_or_default();
            format!(
                "{} {}",
                request.method,
                path.trim_start_matches("https://alpr.test")
            )
        })
        .collect();
    assert_eq!(
        requests,
        [
            "POST /api/v1/discounts",
            "GET /api/v1/discounts/disc_1",
            "GET /api/v1/discounts",
            "GET /api/v1/discounts",
            "DELETE /api/v1/discounts/disc_1"
        ]
    );
    let body: serde_json::Value = serde_json::from_slice(seen[0].body.as_deref().unwrap()).unwrap();
    assert_eq!(
        body,
        serde_json::json!({"name": "Black", "type": "percentage", "duration": "once", "basis_points": 1000})
    );
}

#[test]
fn a_free_form_value_decodes_nested() {
    let state: serde_json::Value = serde_json::from_str(
        r#"{"id":"cus_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}"#,
    )
    .unwrap();
    let (client, _) = client(move |_| json(200, serde_json::json!({ "data": state.clone() })));
    let state = client.customers().get_state("cus_1").unwrap();
    let grant = &state.granted_benefits[0];
    assert_eq!(
        serde_json::to_value(&grant.benefit_metadata).unwrap(),
        serde_json::json!({"flags": {"beta": true, "limits": {"seats": 5, "tiers": ["a", 2, null, 1.5]}}})
    );
    assert_eq!(
        serde_json::to_value(&grant.properties).unwrap(),
        serde_json::json!({"links": [{"url": "https://example.com", "expires": null}]})
    );
}

#[test]
fn a_post_without_a_key_is_sent_with_its_own_a_get_with_none() {
    let (client, seen) = client(|_| json(201, serde_json::json!({"data": product("prod_1")})));
    let params = ProductsCreateParams::new("Curso");
    client.products().create(&params).unwrap();
    client.products().create(&params).unwrap();
    client
        .products()
        .idempotency_key("mine")
        .create(&params)
        .unwrap();
    client.products().get("prod_1").unwrap();
    let seen = seen.lock().unwrap();
    let keys: Vec<Option<&str>> = seen
        .iter()
        .map(|request| request.header("idempotency-key"))
        .collect();
    for key in &keys[..2] {
        let key = key.unwrap();
        let groups: Vec<&str> = key.split('-').collect();
        assert_eq!(
            groups.iter().map(|group| group.len()).collect::<Vec<_>>(),
            [8, 4, 4, 4, 12]
        );
        assert!(key
            .chars()
            .all(|c| c == '-' || c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert!(groups[2].starts_with('4') && "89ab".contains(&groups[3][..1]));
    }
    assert_ne!(keys[0], keys[1]);
    assert_eq!(keys[2], Some("mine"));
    assert_eq!(keys[3], None);
}

#[test]
fn iterating_walks_every_page() {
    let (client, seen) = client(|request| {
        let page = query(&request.url, "page").unwrap();
        json(
            200,
            serde_json::json!({"data": {"items": [product(&format!("prod_{page}"))], "pagination": {"total_count": 3, "max_page": 3}}}),
        )
    });
    let ids: Vec<String> = client
        .products()
        .list_iter(ProductsListParams::new().limit(1))
        .map(|product| product.unwrap().id)
        .collect();
    assert_eq!(ids, ["prod_1", "prod_2", "prod_3"]);
    assert_eq!(
        query(&seen.lock().unwrap()[0].url, "limit").as_deref(),
        Some("1")
    );
}

#[test]
fn a_refusal_is_a_typed_error() {
    let (client, _) = client(|request| {
        if request.url.ends_with("/api/v1/customers") {
            return json(
                422,
                serde_json::json!({"error": "invalid_request", "fields": {"email": ["send an e-mail"]}}),
            );
        }
        HttpResponse::new(429, "").with_header("Retry-After", "7")
    });
    let Err(Error::Api(refused)) = client
        .customers()
        .create(&CustomersCreateParams::new("x", "x"))
    else {
        panic!("a 422 was not refused");
    };
    assert_eq!(
        (refused.status, refused.code.as_str()),
        (422, "invalid_request")
    );
    assert_eq!(refused.fields["email"], ["send an e-mail"]);
    let Err(Error::Api(limited)) = client.products().list(&ProductsListParams::new()) else {
        panic!("a 429 was not refused");
    };
    assert_eq!(
        (limited.status, limited.retry_after),
        (429, Some(Duration::from_secs(7)))
    );
}

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Alpr.sh events signed under two secrets, as while one is rotated.
const REFERENCE_SECRET: &str = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
const OLD_SECRET: &str = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=";
const NEW_SECRET: &str = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=";
const ORDER_PAID: &[u8] = br#"{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}"#;
const USAGE_RECORDED: &[u8] = br#"{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}"#;
const PAYOUT_SENT: &[u8] = br#"{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}"#;
const SIGNED_AT: u64 = 1_792_670_400;

fn webhook_headers(id: &str, at: u64, signature: &str) -> Vec<(String, String)> {
    vec![
        ("Webhook-Id".to_owned(), id.to_owned()),
        ("webhook-timestamp".to_owned(), at.to_string()),
        ("webhook-signature".to_owned(), signature.to_owned()),
    ]
}

#[test]
fn the_standard_webhooks_vector_verifies() {
    let body: &[u8] = br#"{"test": 2432232314}"#;
    let headers = webhook_headers(
        "msg_p5jXN8AQM9LWM0D4loKWxJek",
        1_614_265_330,
        "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=",
    );
    let at = UNIX_EPOCH + Duration::from_secs(1_614_265_330);
    verify_webhook_signature_at(REFERENCE_SECRET, headers.clone(), body, at).unwrap();
    let changed = [body, b" "].concat();
    for (secret, payload, now) in [
        (REFERENCE_SECRET, changed.as_slice(), at),
        (REFERENCE_SECRET, body, at + Duration::from_secs(301)),
        (NEW_SECRET, body, at),
    ] {
        assert!(matches!(
            verify_webhook_signature_at(secret, headers.clone(), payload, now),
            Err(WebhookError::InvalidSignature)
        ));
    }
}

#[test]
fn a_timestamp_that_is_not_plain_digits_is_refused() {
    let body: &[u8] = br#"{"test": 2432232314}"#;
    let at = UNIX_EPOCH + Duration::from_secs(1_614_265_330);
    for (stamp, signature) in [
        (
            "+1614265330",
            "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8=",
        ),
        ("²", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY="),
        ("", "x"),
        ("1_6", "x"),
    ] {
        let headers = vec![
            (
                "Webhook-Id".to_owned(),
                "msg_p5jXN8AQM9LWM0D4loKWxJek".to_owned(),
            ),
            ("webhook-timestamp".to_owned(), stamp.to_owned()),
            ("webhook-signature".to_owned(), format!("v1,{signature}")),
        ];
        assert!(
            matches!(
                verify_webhook_signature_at(REFERENCE_SECRET, headers, body, at),
                Err(WebhookError::InvalidSignature)
            ),
            "{stamp:?} verified"
        );
    }
}

#[test]
fn a_webhook_answers_its_typed_event() {
    let now = UNIX_EPOCH + Duration::from_secs(SIGNED_AT + 120);
    let headers = webhook_headers(
        "msg_2",
        SIGNED_AT,
        "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=",
    );
    for secret in [NEW_SECRET, OLD_SECRET] {
        let WebhookEvent::Order(order) =
            verify_webhook_at(secret, headers.clone(), ORDER_PAID, now).unwrap()
        else {
            panic!("not an order event");
        };
        assert_eq!(
            (
                order.type_.as_str(),
                order.data.id.as_str(),
                order.data.installments,
                order.data.installment_interest_cents
            ),
            ("order.paid", "ord_1", 3, 360)
        );
    }
    assert!(matches!(
        verify_webhook_at(REFERENCE_SECRET, headers, ORDER_PAID, now),
        Err(WebhookError::InvalidSignature)
    ));
    let usage = verify_webhook_at(
        NEW_SECRET,
        webhook_headers(
            "msg_3",
            SIGNED_AT,
            "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=",
        ),
        USAGE_RECORDED,
        now,
    )
    .unwrap();
    assert_eq!(usage.id(), "msg_3");
    let WebhookEvent::Identifiers(usage) = usage else {
        panic!("not an identifiers event");
    };
    assert_eq!(usage.data["merchant_id"], "mer_1");
    let unknown = verify_webhook_at(
        NEW_SECRET,
        webhook_headers(
            "msg_4",
            SIGNED_AT,
            "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=",
        ),
        PAYOUT_SENT,
        now,
    )
    .unwrap();
    assert_eq!(unknown.type_(), "payout.sent");
    let WebhookEvent::Unknown(unknown) = unknown else {
        panic!("not an unknown event");
    };
    assert_eq!(
        unknown.data,
        serde_json::json!({"payout_id": "po_1", "amount_cents": 5000})
    );
}

/// Answers what it was sent, wrapped as the API wraps a resource; a request
/// without the test key is refused with a 401 and Retry-After 3.
fn echo_server() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut parts = line.split_whitespace();
            let (method, target) = (
                parts.next().unwrap_or("").to_owned(),
                parts.next().unwrap_or("").to_owned(),
            );
            let (mut length, mut authorization, mut idempotency) =
                (0, String::new(), String::new());
            loop {
                let mut header = String::new();
                reader.read_line(&mut header).unwrap();
                let header = header.trim_end();
                if header.is_empty() {
                    break;
                }
                let (name, value) = header.split_once(':').unwrap();
                match name.to_ascii_lowercase().as_str() {
                    "content-length" => length = value.trim().parse().unwrap(),
                    "authorization" => authorization = value.trim().to_owned(),
                    "idempotency-key" => idempotency = value.trim().to_owned(),
                    _ => {}
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let (status, extra, answer) = if authorization != "Bearer prk_test_key" {
                (
                    "401 Unauthorized",
                    "Retry-After: 3\r\n",
                    serde_json::json!({"error": "invalid_credential"}),
                )
            } else {
                let sent: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
                let data = serde_json::json!({
                    "id": "prod_1",
                    "name": sent["name"].as_str().unwrap_or(""),
                    "description": idempotency,
                    "status": "active",
                    "created_at": format!("{method} {target}"),
                });
                ("201 Created", "", serde_json::json!({ "data": data }))
            };
            let answer = answer.to_string();
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{answer}",
                answer.len()
            );
        }
    });
    format!("http://{address}")
}

#[test]
fn the_real_http_sends_and_reads_through_ureq() {
    let base_url = echo_server();
    let client = Client::builder("prk_test_key").base_url(&base_url).build();
    let product = client
        .products()
        .idempotency_key("create-1")
        .create(&ProductsCreateParams::new("Curso"))
        .unwrap();
    assert_eq!(product.name, "Curso");
    assert_eq!(product.description, "create-1");
    assert_eq!(product.created_at, "POST /api/v1/products");
    let other = Client::builder("prk_test_other")
        .base_url(&base_url)
        .build();
    let Err(Error::Api(refused)) = other.products().get("prod_1") else {
        panic!("a 401 was not refused");
    };
    assert_eq!(refused.status, 401);
    assert_eq!(refused.code, "invalid_credential");
    assert_eq!(refused.retry_after, Some(Duration::from_secs(3)));
}

/// Answers every request with `response` and counts the connections it gets.
fn canned_server(response: String) -> (String, Arc<std::sync::atomic::AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let count = Arc::clone(&hits);
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            loop {
                let mut header = String::new();
                if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim_end().is_empty() {
                    break;
                }
            }
            let _ = stream.write_all(response.as_bytes());
        }
    });
    (format!("http://{address}"), hits)
}

#[test]
fn a_redirect_is_refused_and_the_key_never_follows_it() {
    let (elsewhere, hits) = canned_server(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".to_owned(),
    );
    let (first, _) = canned_server(format!(
        "HTTP/1.1 302 Found\r\nLocation: {elsewhere}/steal\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    ));
    let client = Client::builder("prk_test_key").base_url(&first).build();
    let Err(Error::Api(refused)) = client.products().get("prod_1") else {
        panic!("a redirect was followed");
    };
    assert_eq!(refused.status, 302);
    assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 0);
}
