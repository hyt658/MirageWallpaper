#!/usr/bin/env python3
# Copyright © 2026 王孝慈. All rights reserved.
"""Package the editor's transparent PNG as a macOS icon without cropping its padding."""

import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / 'assets/MirageEditor.png'


def build_icon(target):
    data = SOURCE.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', data[16:24]) != (1024, 1024) or data[25] != 6:
        raise ValueError('The editor icon must be a 1024×1024 RGBA PNG')
    target = Path(target).resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='mirage-editor-icon-') as directory:
        output = Path(directory)
        iconset = output / 'MirageEditor.iconset'
        iconset.mkdir()
        for points in [16, 32, 128, 256, 512]:
            for scale in [1, 2]:
                pixels = points * scale
                suffix = '@2x' if scale == 2 else ''
                path = iconset / f'icon_{points}x{points}{suffix}.png'
                # Resize the complete canvas; never trim the transparent margin.
                subprocess.run(['/usr/bin/sips', '-z', str(pixels), str(pixels),
                                str(SOURCE), '--out', str(path)],
                               check=True, capture_output=True)
        packaged = output / 'MirageEditor.icns'
        subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(packaged)], check=True)
        temporary = target.with_name(target.name + '.mirage-new')
        shutil.copy2(packaged, temporary)
        temporary.replace(target)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=PROJECT / 'runtime/MirageEditor.icns')
    args = parser.parse_args()
    build_icon(args.output)
    print('Packaged editor icon:', args.output)
