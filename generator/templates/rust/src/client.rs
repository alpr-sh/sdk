use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::Deserialize;
use ureq::RequestExt;

use crate::error::{ApiError, Error};
use crate::multipart::Form;
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
    /// The body of a call that sends one: a multipart form.
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

/// Options of one call.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RequestOptions {
    /// Sends the call with another workspace's key.
    pub api_key: Option<String>,
}

/// Alpr.sh's API with one workspace's API key (`alpr_live_…`), which says the
/// workspace and the scopes the calls may use.
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

/// The `{"data": [...]}` an answer wraps a list in.
#[derive(Deserialize)]
pub(crate) struct Data<T> {
    pub(crate) data: T,
}

impl Client {
    /// A client for the workspace `api_key` belongs to.
    pub fn new(api_key: impl Into<String>) -> Self {
        Self::builder(api_key).build()
    }

    /// Configures a client for the workspace `api_key` belongs to.
    pub fn builder(api_key: impl Into<String>) -> ClientBuilder {
        ClientBuilder {
            api_key: api_key.into(),
            base_url: DEFAULT_BASE_URL.to_owned(),
            timeout: Duration::from_secs(30),
            transport: None,
        }
    }

    /// Calls the API and reads the whole answer as a `T`; a refusal is
    /// [`Error::Api`].
    pub(crate) fn request<T: DeserializeOwned>(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, String)],
        form: Option<Form<'_>>,
        options: &RequestOptions,
    ) -> Result<T, Error> {
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
        let body = form.map(|form| {
            let (body, content_type) = form.encode();
            headers.push(("Content-Type".to_owned(), content_type));
            body
        });
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
        serde_json::from_slice(&response.body).map_err(Error::Json)
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
