use std::fmt;
use std::hash::{BuildHasher, Hasher, RandomState};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use ureq::RequestExt;

use crate::error::{ApiError, Error};
use crate::version::{DEFAULT_BASE_URL, VERSION};

/// Any error a [`Transport`] answers.
pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// One request, as a [`Transport`] sends it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct HttpRequest {
    /// GET, POST…
    pub method: String,
    /// The whole address, with the query.
    pub url: String,
    /// The headers, in the order they are sent.
    pub headers: Vec<(String, String)>,
    /// The JSON body of a write, if it has one.
    pub body: Option<Vec<u8>>,
    /// How long the call may take.
    pub timeout: Duration,
}

impl HttpRequest {
    /// The first value of a header, its name in any case.
    pub fn header(&self, name: &str) -> Option<&str> {
        find(&self.headers, name)
    }
}

/// One answer, as a [`Transport`] reads it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HttpResponse {
    /// The HTTP status.
    pub status: u16,
    /// The headers.
    pub headers: Vec<(String, String)>,
    /// The body.
    pub body: Vec<u8>,
}

impl HttpResponse {
    /// An answer with this status and body and no headers.
    pub fn new(status: u16, body: impl Into<Vec<u8>>) -> Self {
        Self {
            status,
            headers: Vec::new(),
            body: body.into(),
        }
    }

    /// The same answer with one more header.
    pub fn with_header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }

    /// The first value of a header, its name in any case.
    pub fn header(&self, name: &str) -> Option<&str> {
        find(&self.headers, name)
    }
}

fn find<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

/// Sends a request and answers what came back, whatever its status. The SDK
/// sends through [`UreqTransport`]; a test, or a program with its own HTTP
/// client, gives another one to [`ClientBuilder::transport`]. A function
/// from [`HttpRequest`] to `Result<HttpResponse, BoxError>` is one.
pub trait Transport: Send + Sync {
    /// Sends one request.
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, BoxError>;
}

impl<F> Transport for F
where
    F: Fn(HttpRequest) -> Result<HttpResponse, BoxError> + Send + Sync,
{
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, BoxError> {
        self(request)
    }
}

/// The HTTP the SDK sends through: [ureq](https://docs.rs/ureq), blocking,
/// with rustls.
#[derive(Debug, Clone)]
pub struct UreqTransport {
    agent: ureq::Agent,
}

impl UreqTransport {
    /// A transport with its own connection pool.
    pub fn new() -> Self {
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            // The API never redirects, and a redirect would carry the key along.
            .max_redirects(0)
            .max_redirects_will_error(false)
            .build()
            .new_agent();
        Self { agent }
    }
}

impl Default for UreqTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl Transport for UreqTransport {
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, BoxError> {
        let mut builder = ureq::http::Request::builder()
            .method(request.method.as_str())
            .uri(request.url.as_str());
        for (name, value) in &request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        let timeout = Some(request.timeout);
        let mut response = match request.body {
            Some(body) => builder
                .body(body)?
                .with_agent(&self.agent)
                .configure()
                .timeout_global(timeout)
                .run()?,
            None => builder
                .body(())?
                .with_agent(&self.agent)
                .configure()
                .timeout_global(timeout)
                .run()?,
        };
        let headers = response
            .headers()
            .iter()
            .filter_map(|(name, value)| {
                Some((name.as_str().to_owned(), value.to_str().ok()?.to_owned()))
            })
            .collect();
        let status = response.status().as_u16();
        let body = response.body_mut().read_to_vec()?;
        Ok(HttpResponse {
            status,
            headers,
            body,
        })
    }
}

/// Options of one call: the key it is made with and, for a write, the key
/// that makes it safe to repeat.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RequestOptions {
    /// Makes a write safe to repeat: the same key with the same body answers
    /// the first response again; with another body, a 409. A POST without one
    /// is sent with a random key of its own, one a call.
    pub idempotency_key: Option<String>,
    /// Sends the call with another organization's key.
    pub api_key: Option<String>,
}

/// Alpr.sh's API with one organization's API key. The key says the
/// organization and the environment: `prk_test_…` is the test environment,
/// `prk_live_…` the live one.
///
/// A client is cheap to clone, and its clones share one connection pool.
#[derive(Clone)]
pub struct Client {
    api_key: String,
    base_url: String,
    timeout: Duration,
    transport: Arc<dyn Transport>,
}

impl fmt::Debug for Client {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Client")
            .field("base_url", &self.base_url)
            .field("timeout", &self.timeout)
            .finish_non_exhaustive()
    }
}

/// Configures a [`Client`].
pub struct ClientBuilder {
    api_key: String,
    base_url: String,
    timeout: Duration,
    transport: Option<Arc<dyn Transport>>,
}

impl fmt::Debug for ClientBuilder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClientBuilder")
            .field("base_url", &self.base_url)
            .field("timeout", &self.timeout)
            .finish_non_exhaustive()
    }
}

impl ClientBuilder {
    /// Points the client at another address, such as a local server. It must
    /// be https; http is accepted only for localhost, 127.0.0.0/8 and ::1,
    /// and any other makes every call answer [`Error::InsecureBaseUrl`]
    /// before anything is sent.
    pub fn base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = base_url.into().trim_end_matches('/').to_owned();
        self
    }

    /// How long a call may take; 30 seconds by default.
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Sends the requests through `transport`.
    pub fn transport(mut self, transport: impl Transport + 'static) -> Self {
        self.transport = Some(Arc::new(transport));
        self
    }

    /// The client.
    pub fn build(self) -> Client {
        Client {
            api_key: self.api_key,
            base_url: self.base_url,
            timeout: self.timeout,
            transport: self
                .transport
                .unwrap_or_else(|| Arc::new(UreqTransport::new())),
        }
    }
}

#[derive(Deserialize)]
struct Envelope<T> {
    data: T,
}

impl Client {
    /// A client for the organization `api_key` belongs to.
    pub fn new(api_key: impl Into<String>) -> Self {
        Self::builder(api_key).build()
    }

    /// Configures a client for the organization `api_key` belongs to.
    pub fn builder(api_key: impl Into<String>) -> ClientBuilder {
        ClientBuilder {
            api_key: api_key.into(),
            base_url: DEFAULT_BASE_URL.to_owned(),
            timeout: Duration::from_secs(30),
            transport: None,
        }
    }

    /// Calls the API and answers what it wrapped in `data`; a refusal is
    /// [`Error::Api`].
    pub(crate) fn request<T, B>(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, String)],
        body: Option<&B>,
        options: &RequestOptions,
    ) -> Result<T, Error>
    where
        T: DeserializeOwned,
        B: Serialize + ?Sized,
    {
        if !secure_base_url(&self.base_url) {
            return Err(Error::InsecureBaseUrl);
        }
        let mut url = format!("{}{}", self.base_url, path);
        let pairs: Vec<String> = query
            .iter()
            .filter(|(_, value)| !value.is_empty())
            .map(|(name, value)| format!("{}={}", escape(name), escape(value)))
            .collect();
        if !pairs.is_empty() {
            url.push('?');
            url.push_str(&pairs.join("&"));
        }
        let api_key = options.api_key.as_deref().unwrap_or(&self.api_key);
        let mut headers = vec![
            ("Authorization".to_owned(), format!("Bearer {api_key}")),
            ("Accept".to_owned(), "application/json".to_owned()),
            ("User-Agent".to_owned(), format!("alpr-rust/{VERSION}")),
        ];
        let body = match body {
            Some(body) => {
                headers.push(("Content-Type".to_owned(), "application/json".to_owned()));
                Some(serde_json::to_vec(body).map_err(Error::Json)?)
            }
            None => None,
        };
        let key = options
            .idempotency_key
            .as_deref()
            .filter(|key| !key.is_empty())
            .map(str::to_owned)
            .or_else(|| (method == "POST").then(new_idempotency_key));
        if let Some(key) = key {
            headers.push(("Idempotency-Key".to_owned(), key));
        }
        let request = HttpRequest {
            method: method.to_owned(),
            url,
            headers,
            body,
            timeout: self.timeout,
        };
        let response = self.transport.send(request).map_err(Error::Transport)?;
        if response.status >= 300 {
            return Err(Error::Api(ApiError::from_response(&response)));
        }
        if response.status == 204 {
            // No body: only a request for `()` can read it.
            return serde_json::from_slice(b"null").map_err(Error::Json);
        }
        let envelope: Envelope<T> = serde_json::from_slice(&response.body).map_err(Error::Json)?;
        Ok(envelope.data)
    }
}

/// Says the base URL is https, or http to localhost, 127.0.0.0/8 or ::1.
fn secure_base_url(base_url: &str) -> bool {
    let Ok(uri) = base_url.parse::<ureq::http::Uri>() else {
        return false;
    };
    let host = uri
        .host()
        .unwrap_or("")
        .trim_matches(['[', ']'])
        .to_ascii_lowercase();
    let loopback = host == "localhost"
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|address| address.is_loopback());
    match uri.scheme_str().map(str::to_ascii_lowercase).as_deref() {
        Some("https") => true,
        Some("http") => loopback,
        _ => false,
    }
}

/// A random UUID (version 4). The standard library has no CSPRNG and the SDK
/// takes no dependency for one, so the bytes are SipHash outputs under keys the
/// operating system seeds for each [`RandomState`], mixed with a counter and
/// the clock: a key has to be unique, not secret.
fn new_idempotency_key() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    let mut bytes = [0u8; 16];
    for half in bytes.chunks_mut(8) {
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_u64(COUNTER.fetch_add(1, Ordering::Relaxed));
        hasher.write_u128(nanos);
        half.copy_from_slice(&hasher.finish().to_be_bytes());
    }
    bytes[6] = bytes[6] & 0x0f | 0x40;
    bytes[8] = bytes[8] & 0x3f | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// A path parameter or a query value, escaped: everything but letters,
/// digits and `-._~`.
pub(crate) fn escape(value: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(byte as char);
        } else {
            out.push('%');
            out.push(HEX[usize::from(byte >> 4)] as char);
            out.push(HEX[usize::from(byte & 15)] as char);
        }
    }
    out
}
