<?php

declare(strict_types=1);

namespace Alpr;

/**
 * A multipart/form-data body, written by hand: one photo and the text fields
 * beside it. The photo is named and typed by what its first bytes say it is.
 */
final class Form
{
    /** @var list<array{name: string, file: bool, value: string}> */
    private array $parts = [];

    /** Adds a text field; a float is written in its shortest decimal form (0.5). */
    public function text(string $name, string|int|float|bool $value): self
    {
        $this->parts[] = ['name' => $name, 'file' => false, 'value' => self::write($value)];
        return $this;
    }

    /** Adds the photo: its bytes, as they are. */
    public function file(string $name, string $data): self
    {
        $this->parts[] = ['name' => $name, 'file' => true, 'value' => $data];
        return $this;
    }

    /**
     * The body and its Content-Type, boundary included. A boundary is chosen
     * that no part contains, unless one is given.
     *
     * @return array{0: string, 1: string}
     */
    public function encode(?string $boundary = null): array
    {
        $boundary ??= $this->boundary();
        $body = '';
        foreach ($this->parts as $part) {
            $name = self::escape($part['name']);
            if (!$part['file']) {
                $body .= "--{$boundary}\r\nContent-Disposition: form-data; name=\"{$name}\"\r\n\r\n{$part['value']}\r\n";
                continue;
            }
            [$type, $filename] = self::imageType($part['value']);
            $body .= "--{$boundary}\r\nContent-Disposition: form-data; name=\"{$name}\"; filename=\"{$filename}\"\r\nContent-Type: {$type}\r\n\r\n{$part['value']}\r\n";
        }
        return [$body . "--{$boundary}--\r\n", 'multipart/form-data; boundary=' . $boundary];
    }

    /**
     * The content type and file name of a photo: JPEG and PNG are what the API
     * reads, and anything else goes as bytes for the API to refuse.
     *
     * @return array{0: string, 1: string}
     */
    public static function imageType(string $data): array
    {
        if (str_starts_with($data, "\xFF\xD8\xFF")) {
            return ['image/jpeg', 'photo.jpg'];
        }
        if (str_starts_with($data, "\x89PNG\r\n\x1A\n")) {
            return ['image/png', 'photo.png'];
        }
        return ['application/octet-stream', 'photo'];
    }

    private function boundary(): string
    {
        while (true) {
            $boundary = 'alpr-' . bin2hex(random_bytes(16));
            foreach ($this->parts as $part) {
                if (str_contains($part['value'], $boundary)) {
                    continue 2;
                }
            }
            return $boundary;
        }
    }

    private static function write(string|int|float|bool $value): string
    {
        return match (true) {
            is_bool($value) => $value ? 'true' : 'false',
            is_float($value) => json_encode($value, JSON_THROW_ON_ERROR),
            default => (string) $value,
        };
    }

    /** A field name inside quotes: no quote, backslash or line break gets out. */
    private static function escape(string $name): string
    {
        return str_replace(['\\', '"', "\r", "\n"], ['\\\\', '%22', '%0D', '%0A'], $name);
    }
}
