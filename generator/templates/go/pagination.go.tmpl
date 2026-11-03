package alpr

import "iter"

// Page is one page of a list: its items, and the cursor of the next page.
type Page[T any] struct {
	Items []T `json:"data"`
	// Next is the cursor to ask the next page with; empty on the last page.
	Next string `json:"next"`
}

// iterate walks pages from the cursor first (the newest page when empty)
// until the last one, yielding every item and stopping at the first error.
func iterate[T any](fetch func(cursor string) (*Page[T], error), first string) iter.Seq2[T, error] {
	return func(yield func(T, error) bool) {
		cursor := first
		for {
			result, err := fetch(cursor)
			if err != nil {
				var zero T
				yield(zero, err)
				return
			}
			for _, item := range result.Items {
				if !yield(item, nil) {
					return
				}
			}
			// A cursor that does not move would ask for the same page forever.
			if result.Next == "" || result.Next == cursor {
				return
			}
			cursor = result.Next
		}
	}
}
