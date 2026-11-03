package alpr

import (
	"fmt"
	"time"
)

// Error is a request the API refused. Code is the API's: invalid_api_key,
// insufficient_scope, insufficient_credits, missing image, invalid_image,
// invalid_option, image_too_large, no_plate, not_found, image_unavailable,
// rate_limited, engine_unavailable or storage_unavailable. Fields says, when
// the API names them, what is wrong with each field. RetryAfter is how long
// to wait on a 429.
type Error struct {
	StatusCode int
	Code       string
	Message    string
	Fields     map[string][]string
	RetryAfter time.Duration
}

func (e *Error) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("alpr: %d %s: %s", e.StatusCode, e.Code, e.Message)
	}
	return fmt.Sprintf("alpr: %d %s", e.StatusCode, e.Code)
}
