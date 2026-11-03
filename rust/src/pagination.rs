use std::collections::VecDeque;

use serde::{Deserialize, Serialize};

use crate::error::Error;

/// One page of a list, and the cursor of the next one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Page<T> {
    /// The page's items.
    #[serde(rename = "data", default = "Vec::new")]
    pub items: Vec<T>,
    /// The cursor to ask the next page with; `None` on the last page.
    #[serde(default)]
    pub next: Option<String>,
}

/// Walks pages from the cursor `first` (the newest page when `None`) until
/// the last one, yielding every item. A page is fetched only when the items
/// before it were taken, a cursor that does not move ends the walk, and an
/// error ends it too.
pub(crate) fn iterate<'a, T: 'a>(
    first: Option<String>,
    mut fetch: impl FnMut(Option<&str>) -> Result<Page<T>, Error> + 'a,
) -> impl Iterator<Item = Result<T, Error>> + 'a {
    let mut cursor = first.filter(|cursor| !cursor.is_empty());
    let mut items = VecDeque::new();
    let mut done = false;
    std::iter::from_fn(move || loop {
        if let Some(item) = items.pop_front() {
            return Some(Ok(item));
        }
        if done {
            return None;
        }
        match fetch(cursor.as_deref()) {
            Ok(result) => {
                items.extend(result.items);
                // A cursor that does not move would ask for the same page forever.
                match result.next.filter(|next| !next.is_empty()) {
                    Some(next) if cursor.as_deref() != Some(next.as_str()) => cursor = Some(next),
                    _ => done = true,
                }
            }
            Err(error) => {
                done = true;
                return Some(Err(error));
            }
        }
    })
}
