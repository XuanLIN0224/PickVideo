#!/usr/bin/env python3
"""Fetch the pinned official engine and verify it before use."""
import hashlib
import os
from pathlib import Path
import tempfile
import urllib.request

VERSION = "2026.08.19"
SHA256 = "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"
URL = f"https://github.com/yt-dlp/yt-dlp/releases/download/{VERSION}/yt-dlp_macos"
root = Path(__file__).resolve().parent / "Resources"
root.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(dir=root, delete=False) as stream:
    temporary = Path(stream.name)
    try:
        with urllib.request.urlopen(URL, timeout=60) as response:
            while chunk := response.read(1024 * 1024):
                stream.write(chunk)
        stream.flush()
        with temporary.open("rb") as downloaded:
            actual = hashlib.file_digest(downloaded, "sha256").hexdigest()
        if actual != SHA256:
            raise RuntimeError("The engine checksum does not match the official release.")
        os.chmod(temporary, 0o755)
        os.replace(temporary, root / "yt-dlp")
        print(f"Verified yt-dlp {VERSION}")
    finally:
        temporary.unlink(missing_ok=True)
