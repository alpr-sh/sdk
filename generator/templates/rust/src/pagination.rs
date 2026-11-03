use std::collections::VecDeque;

use serde::{Deserialize, Serialize};

use crate::error::Error;
use crate::models::Pagination;

/// One page of a list, and where the list ends.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Page<T> {
    /// The page's items.
    #[serde(default = "Vec::new")]
    pub items: Vec<T>,
    /// How many items and pages the list has.
    pub pagination: Pagination,
}

/// Walks pages from `first` (1 when zero) until the last one, as Polar's SDKs
/// do, yielding every item. A page is fetched only when the items before it
/// were taken, and an error ends the walk.
pub(crate) fn iterate<'a, T: 'a>(
    first: u32,
    mut fetch: impl FnMut(u32) -> Result<Page<T>, Error> + 'a,
) -> impl Iterator<Item = Result<T, Error>> + 'a {
    let mut page = first.max(1);
    let mut items = VecDeque::new();
    let mut done = false;
    std::iter::from_fn(move || loop {
        if let Some(item) = items.pop_front() {
            return Some(Ok(item));
        }
        if done {
            return None;
        }
        match fetch(page) {
            Ok(result) => {
                if i64::from(page) >= result.pagination.max_page {
                    done = true;
                } else {
                    page += 1;
                }
                items.extend(result.items);
            }
            Err(error) => {
                done = true;
                return Some(Err(error));
            }
        }
    })
}
