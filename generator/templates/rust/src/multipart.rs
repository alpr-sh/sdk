use std::hash::{BuildHasher, Hasher, RandomState};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// A `multipart/form-data` body: one file and the text fields beside it.
/// The standard library has no encoder for it, so this one is written by
/// hand.
#[derive(Debug, Default)]
pub(crate) struct Form<'a> {
    parts: Vec<Part<'a>>,
}

#[derive(Debug)]
enum Part<'a> {
    Text { name: &'static str, value: String },
    File { name: &'static str, data: &'a [u8] },
}

impl<'a> Form<'a> {
    /// An empty form.
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Adds a text field.
    pub(crate) fn text(&mut self, name: &'static str, value: String) {
        self.parts.push(Part::Text { name, value });
    }

    /// Adds the photo, named and typed by what its first bytes say it is.
    pub(crate) fn file(&mut self, name: &'static str, data: &'a [u8]) {
        self.parts.push(Part::File { name, data });
    }

    /// Writes the body and its `Content-Type`, boundary included.
    pub(crate) fn encode(&self) -> (Vec<u8>, String) {
        let boundary = self.boundary();
        let mut body = Vec::new();
        for part in &self.parts {
            body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
            match part {
                Part::Text { name, value } => {
                    body.extend_from_slice(
                        format!("Content-Disposition: form-data; name=\"{name}\"\r\n\r\n")
                            .as_bytes(),
                    );
                    body.extend_from_slice(value.as_bytes());
                }
                Part::File { name, data } => {
                    let (kind, filename) = image_type(data);
                    body.extend_from_slice(
                        format!(
                            "Content-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\r\nContent-Type: {kind}\r\n\r\n"
                        )
                        .as_bytes(),
                    );
                    body.extend_from_slice(data);
                }
            }
            body.extend_from_slice(b"\r\n");
        }
        body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
        (body, format!("multipart/form-data; boundary={boundary}"))
    }

    /// A boundary no part contains.
    fn boundary(&self) -> String {
        loop {
            let candidate = random_hex();
            let taken = self.parts.iter().any(|part| match part {
                Part::Text { value, .. } => contains(value.as_bytes(), candidate.as_bytes()),
                Part::File { data, .. } => contains(data, candidate.as_bytes()),
            });
            if !taken {
                return format!("alpr-{candidate}");
            }
        }
    }
}

/// Says `needle` is somewhere in `haystack`.
fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

/// The content type and file name of a photo: JPEG and PNG are what the API
/// reads, and anything else goes as bytes for the API to refuse.
pub(crate) fn image_type(data: &[u8]) -> (&'static str, &'static str) {
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        ("image/jpeg", "photo.jpg")
    } else if data.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        ("image/png", "photo.png")
    } else {
        ("application/octet-stream", "photo")
    }
}

/// 32 random hex characters. The standard library has no CSPRNG and the SDK
/// takes no dependency for one, so the digits are SipHash outputs under keys
/// the operating system seeds for each [`RandomState`], mixed with a counter
/// and the clock: a boundary has to be unique, not secret.
fn random_hex() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    let mut out = String::with_capacity(32);
    for _ in 0..2 {
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_u64(COUNTER.fetch_add(1, Ordering::Relaxed));
        hasher.write_u128(nanos);
        out.push_str(&format!("{:016x}", hasher.finish()));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_photo_is_named_by_its_first_bytes() {
        assert_eq!(
            image_type(&[0xFF, 0xD8, 0xFF, 0xE0]),
            ("image/jpeg", "photo.jpg")
        );
        assert_eq!(
            image_type(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0]),
            ("image/png", "photo.png")
        );
        assert_eq!(image_type(b"GIF89a"), ("application/octet-stream", "photo"));
        assert_eq!(image_type(&[]), ("application/octet-stream", "photo"));
    }

    #[test]
    fn the_body_is_framed_by_its_boundary() {
        let mut form = Form::new();
        form.text("a", "1".to_owned());
        form.file("image", &[0xFF, 0xD8, 0xFF, 1, 2, 3]);
        let (body, content_type) = form.encode();
        let boundary = content_type
            .strip_prefix("multipart/form-data; boundary=")
            .unwrap();
        let text = String::from_utf8_lossy(&body);
        assert!(text.starts_with(&format!("--{boundary}\r\n")));
        assert!(text.ends_with(&format!("\r\n--{boundary}--\r\n")));
        assert!(text.contains("Content-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n"));
        assert!(text.contains("name=\"image\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg"));
    }
}
