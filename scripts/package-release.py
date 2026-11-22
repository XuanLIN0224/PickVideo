#!/usr/bin/env python3
"""Package a verified Apple Silicon app without personal data or credentials."""

import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


def run(*arguments):
    subprocess.run([str(argument) for argument in arguments], check=True)


def package(app: Path, output: Path):
    app = app.resolve(strict=True)
    output = output.resolve()
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = metadata['CFBundleShortVersionString']
    if not version or any(character not in '0123456789.' for character in version):
        raise ValueError('Release version must contain only digits and periods')
    if metadata['CFBundleIdentifier'] != 'app.pickvideo.desktop':
        raise ValueError('Unexpected application identifier')
    architectures = subprocess.check_output([
        '/usr/bin/lipo', '-archs', str(app / 'Contents/MacOS/PickVideo'),
    ], text=True).split()
    if architectures != ['arm64']:
        raise ValueError(f'Expected the tested arm64 application, received {architectures}')
    forbidden = {'cookies.txt', 'history.json', '.env', '__pycache__', '.DS_Store'}
    for item in app.rglob('*'):
        if item.name in forbidden or item.name.endswith(('.cookies', '.part', '.aria2', '.info.json')):
            raise ValueError(f'Unexpected local data inside application: {item.relative_to(app)}')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'PickVideo-v{version}-macos-arm64.zip'
    disk_image = output / f'PickVideo-v{version}-macos-arm64.dmg'
    for target in (archive, disk_image, output / 'SHA256SUMS.txt'):
        if target.exists():
            raise FileExistsError(f'Refusing to overwrite an existing release asset: {target.name}')
    run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
    with zipfile.ZipFile(archive) as contents:
        if contents.testzip() is not None:
            raise RuntimeError('Release ZIP integrity check failed')
    with tempfile.TemporaryDirectory(prefix='pickvideo-package-') as temporary:
        extracted = Path(temporary) / 'zip-check'
        run('/usr/bin/ditto', '-x', '-k', archive, extracted)
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', extracted / app.name)
        stage = Path(temporary) / 'volume'
        stage.mkdir()
        run('/usr/bin/ditto', app, stage / app.name)
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', stage / app.name)
        (stage / 'Applications').symlink_to('/Applications')
        guide = Path(__file__).resolve().parents[1] / 'docs/INSTALL.zh-CN.md'
        shutil.copyfile(guide, stage / '安装说明.md')
        run('/usr/bin/hdiutil', 'create', '-volname', 'PickVideo', '-srcfolder', stage,
            '-format', 'UDZO', disk_image)
    run('/usr/bin/hdiutil', 'verify', disk_image)
    checksums = []
    for asset in (archive, disk_image):
        with asset.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        checksums.append(f'{digest}  {asset.name}\n')
    (output / 'SHA256SUMS.txt').write_text(''.join(checksums), encoding='utf-8')
    print(f'Packaged PickVideo {version} for Apple Silicon in {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    options = parser.parse_args()
    package(options.app, options.output)
