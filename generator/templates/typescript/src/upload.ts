/** A photo: its bytes, or a Blob (a File too). JPEG and PNG are what the API reads. */
export type Photo = Blob | Uint8Array | ArrayBuffer;

/** What a photo's first bytes say it is: its content type and file name. */
export function imageType(head: Uint8Array): { type: string; name: string } {
  if (head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) {
    return { type: "image/jpeg", name: "photo.jpg" };
  }
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (png.every((byte, i) => head[i] === byte)) {
    return { type: "image/png", name: "photo.png" };
  }
  return { type: "application/octet-stream", name: "photo" };
}

/** The photo as a file part, named and typed by its bytes. */
export async function photoFile(photo: Photo): Promise<File> {
  let bytes: Uint8Array<ArrayBuffer>;
  if (photo instanceof Blob) {
    bytes = new Uint8Array(await photo.arrayBuffer());
  } else if (photo instanceof Uint8Array) {
    bytes = new Uint8Array(photo);
  } else {
    bytes = new Uint8Array(photo.slice(0));
  }
  const { type, name } = imageType(bytes.subarray(0, 8));
  return new File([bytes], name, { type });
}

/** A multipart body: photos as file parts, the other values as text, absent ones left out. */
export async function toForm(params: object): Promise<FormData> {
  const form = new FormData();
  for (const [name, value] of Object.entries(params)) {
    if (value === undefined || value === null) {
      continue;
    }
    if (value instanceof Blob || value instanceof Uint8Array || value instanceof ArrayBuffer) {
      form.append(name, await photoFile(value));
    } else {
      form.append(name, String(value));
    }
  }
  return form;
}
