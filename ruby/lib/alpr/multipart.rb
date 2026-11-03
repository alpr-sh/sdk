# frozen_string_literal: true

require "securerandom"

module Alpr
  # A multipart/form-data body, written by hand: one file and the text fields
  # beside it.
  class Form
    # The Content-Type and file name of a photo, told by its first bytes: JPEG
    # and PNG are what the API reads, and anything else goes as bytes for the
    # API to refuse.
    JPEG_MAGIC = "\xFF\xD8\xFF".b.freeze
    PNG_MAGIC = "\x89PNG\r\n\x1A\n".b.freeze

    def self.image_type(data)
      head = data.byteslice(0, 8).to_s.b
      return ["image/jpeg", "photo.jpg"] if head.start_with?(JPEG_MAGIC)
      return ["image/png", "photo.png"] if head.start_with?(PNG_MAGIC)

      ["application/octet-stream", "photo"]
    end

    # A number, boolean or string as the text of a field: the shortest decimal
    # form, 0.5 and 1, not 0.50 or 1.0.
    def self.text_of(value)
      return value.to_s unless value.is_a?(Float) && value.finite?

      value == value.floor && value.abs < 1e15 ? value.to_i.to_s : value.to_s.sub(/\.0e/, "e")
    end

    def initialize
      @parts = []
    end

    # Adds a text field.
    def text(name, value)
      @parts << [:text, name.to_s, Form.text_of(value).b]
      self
    end

    # Adds the photo, named and typed by what its first bytes say it is.
    def file(name, data)
      raise ArgumentError, "alpr: #{name} is the bytes of a photo (a String), not #{data.class}" unless data.is_a?(String)

      @parts << [:file, name.to_s, data.b]
      self
    end

    # The body, as bytes.
    def body
      encode.first
    end

    # The Content-Type header, boundary included.
    def content_type
      "multipart/form-data; boundary=#{encode.last}"
    end

    private

    # Writes the body once, with a boundary no part contains.
    def encode
      @encoded ||= begin
        boundary = nil
        loop do
          boundary = "alpr-#{SecureRandom.hex(16)}".b
          break unless @parts.any? { |_, _, data| data.include?(boundary) }
        end
        out = "".b
        @parts.each do |kind, name, data|
          out << "--".b << boundary << "\r\n".b
          if kind == :file
            type, filename = Form.image_type(data)
            out << %(Content-Disposition: form-data; name="#{quote(name)}"; filename="#{filename}"\r\n).b
            out << "Content-Type: #{type}\r\n".b
          else
            out << %(Content-Disposition: form-data; name="#{quote(name)}"\r\n).b
          end
          out << "\r\n".b << data << "\r\n".b
        end
        out << "--".b << boundary << "--\r\n".b
        [out, boundary]
      end
    end

    def quote(name)
      name.gsub(/["\r\n]/) { |char| format("%%%02X", char.ord) }
    end
  end
end
