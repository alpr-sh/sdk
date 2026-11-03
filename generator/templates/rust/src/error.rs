use std::collections::HashMap;
use std::fmt;
use std::time::Duration;

use serde::Deserialize;

use crate::client::{BoxError, HttpResponse};

/// What a call answers instead of its resource.
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// The API refused the request.
    Api(ApiError),
    /// The request did not reach the API, or its answer did not arrive.
    Transport(BoxError),
    /// A body could not be written as JSON, or the API answered something
    /// this SDK does not read.
    Json(serde_json::Error),
    /// The client's base URL is not https and not a loopback address, so no
    /// request was sent: the API key would cross the network in clear text.
    InsecureBaseUrl,
}

/// A request the API refused.
///
/// `code` is the API's: invalid_credential, forbidden, not_found,
/// invalid_request, conflict, idempotency_conflict, body_too_large or
/// unavailable. `fields` says, for invalid_request, what is wrong with each
/// field. `retry_after` is how long to wait on a 429.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct ApiError {
    /// The HTTP status.
    pub status: u16,
    /// The API's code for the refusal.
    pub code: String,
    /// What went wrong, for a person to read.
    pub message: String,
    /// The problems of each field of the request.
    pub fields: HashMap<String, Vec<String>>,
    /// How long to wait before trying again.
    pub retry_after: Option<Duration>,
}

#[derive(Deserialize, Default)]
struct ErrorBody {
    error: Option<String>,
    message: Option<String>,
    fields: Option<HashMap<String, Vec<String>>>,
}

impl ApiError {
    /// The error a refused response carries. A refusal without a JSON body is
    /// still a refusal.
    pub(crate) fn from_response(response: &HttpResponse) -> Self {
        let body: ErrorBody = serde_json::from_slice(&response.body).unwrap_or_default();
        Self {
            status: response.status,
            code: body.error.unwrap_or_default(),
            message: body.message.unwrap_or_default(),
            fields: body.fields.unwrap_or_default(),
            retry_after: response
                .header("retry-after")
                .and_then(|value| value.trim().parse::<u64>().ok())
                .map(Duration::from_secs),
        }
    }
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.message.is_empty() {
            write!(f, "alpr: {} {}", self.status, self.code)
        } else {
            write!(f, "alpr: {} {}: {}", self.status, self.code, self.message)
        }
    }
}

impl std::error::Error for ApiError {}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Api(error) => error.fmt(f),
            Error::Transport(error) => write!(f, "alpr: {error}"),
            Error::Json(error) => write!(f, "alpr: json: {error}"),
            Error::InsecureBaseUrl => f.write_str("alpr: the base URL must be https (http is accepted only for localhost, 127.0.0.0/8 and ::1), so the API key is never sent in clear text"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Api(error) => Some(error),
            Error::Transport(error) => Some(error.as_ref()),
            Error::Json(error) => Some(error),
            Error::InsecureBaseUrl => None,
        }
    }
}

impl From<ApiError> for Error {
    fn from(error: ApiError) -> Self {
        Error::Api(error)
    }
}

impl Error {
    /// The refusal, when the API refused the request.
    pub fn api(&self) -> Option<&ApiError> {
        match self {
            Error::Api(error) => Some(error),
            _ => None,
        }
    }
}
