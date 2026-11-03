package alpr

import (
	"bytes"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/textproto"
)

// form is a multipart/form-data body: one file and the text fields beside it.
type form struct {
	parts []formPart
}

type formPart struct {
	name  string
	file  bool
	value string
	data  []byte
}

// text adds a text field.
func (f *form) text(name, value string) {
	f.parts = append(f.parts, formPart{name: name, value: value})
}

// file adds the photo, named and typed by what its first bytes say it is.
func (f *form) file(name string, data []byte) {
	f.parts = append(f.parts, formPart{name: name, file: true, data: data})
}

// encode writes the body and its Content-Type, boundary included.
func (f *form) encode() ([]byte, string, error) {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	for _, part := range f.parts {
		if !part.file {
			if err := w.WriteField(part.name, part.value); err != nil {
				return nil, "", err
			}
			continue
		}
		kind, filename := imageType(part.data)
		header := textproto.MIMEHeader{}
		header.Set("Content-Disposition", fmt.Sprintf(`form-data; name=%q; filename=%q`, part.name, filename))
		header.Set("Content-Type", kind)
		file, err := w.CreatePart(header)
		if err != nil {
			return nil, "", err
		}
		if _, err := file.Write(part.data); err != nil {
			return nil, "", err
		}
	}
	if err := w.Close(); err != nil {
		return nil, "", err
	}
	return buf.Bytes(), w.FormDataContentType(), nil
}

// imageType is the content type and file name of a photo: JPEG and PNG are
// what the API reads, and anything else goes as bytes for the API to refuse.
func imageType(data []byte) (string, string) {
	switch kind := http.DetectContentType(data); kind {
	case "image/jpeg":
		return kind, "photo.jpg"
	case "image/png":
		return kind, "photo.png"
	}
	return "application/octet-stream", "photo"
}
