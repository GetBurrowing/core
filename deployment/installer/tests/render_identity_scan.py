"""Rendered text for identity guards, excluding generated credential values."""

from burrow_install.secrets import redact


def identity_scan_text(rendered):
    """Keep every rendered file and redact only known generated values."""
    return "\n".join(identity_scan_files(rendered).values())


def identity_scan_files(rendered):
    """``{relative path: text}`` with only known generated values redacted.

    A random generated value can hold any short literal (a 48-char hex
    password holds '7881' in about 0.2% of renders), so an absence check over
    a file that carries secrets must search this, not the raw text.
    """
    return {rel: redact(text, rendered.generated) for rel, (text, _mode) in rendered.files.items()}


def planted_like(sample, index):
    """A value of ``sample``'s length and alphabet holding 4080, 7881 and 7882.

    Digits and a-f are in the hex, urlsafe and base64 alphabets alike; base64
    '=' padding is kept. A leading 4080 makes ':4080' appear in a DB URL.
    """
    pad = len(sample) - len(sample.rstrip("="))
    body = f"4080{index:02x}7881{index:02x}7882" + "abcdef" * len(sample)
    return body[: len(sample) - pad] + "=" * pad
