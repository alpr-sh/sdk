/** Options for one call. */
export interface RequestOptions {
  /** Sends this call with another workspace's key. */
  apiKey?: string;
  /** Cancels the call. */
  signal?: AbortSignal;
}

/** A query string's values; undefined ones are left out. */
export type Query = Record<string, string | number | undefined>;

export interface RequestSpec {
  query?: Query;
  /** A multipart body, for the calls that send a photo. */
  form?: FormData;
  options?: RequestOptions | undefined;
}

/** What a service calls the API through. */
export interface Requester {
  request<T>(method: string, path: string, spec?: RequestSpec): Promise<T>;
}
