/**
 * A request the API refused. `code` is the API's: invalid_api_key,
 * insufficient_scope, insufficient_credits, missing image, invalid_image,
 * invalid_option, image_too_large, no_plate, not_found, image_unavailable,
 * rate_limited, engine_unavailable or storage_unavailable. `fields` says, when
 * the API names them, what is wrong with each field. `retryAfter` is how many
 * seconds to wait on a 429.
 */
export class AlprError extends Error {
  readonly status: number;
  readonly code: string;
  readonly fields: Record<string, string[]>;
  readonly retryAfter: number | undefined;

  constructor(status: number, code: string, message: string, fields: Record<string, string[]> = {}, retryAfter?: number) {
    super(message ? `alpr: ${status} ${code}: ${message}` : `alpr: ${status} ${code}`);
    this.name = "AlprError";
    this.status = status;
    this.code = code;
    this.fields = fields;
    this.retryAfter = retryAfter;
  }

  /** The error a refused response carries. */
  static async from(response: Response): Promise<AlprError> {
    let body: { error?: string; message?: string; fields?: Record<string, string[]> } = {};
    try {
      body = (await response.json()) as typeof body;
    } catch {
      // A refusal without a JSON body is still a refusal.
    }
    const seconds = Number.parseInt(response.headers.get("retry-after") ?? "", 10);
    return new AlprError(response.status, body.error ?? "", body.message ?? "", body.fields ?? {}, Number.isNaN(seconds) ? undefined : seconds);
  }
}
