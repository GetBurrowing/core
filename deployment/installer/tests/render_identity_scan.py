"""Rendered text for identity guards, excluding generated credential values."""

from burrow_install.secrets import redact


def identity_scan_text(rendered):
    """Keep every rendered file and redact only known generated values."""
    return "\n".join(
        redact(text, rendered.generated) for text, _mode in rendered.files.values()
    )
