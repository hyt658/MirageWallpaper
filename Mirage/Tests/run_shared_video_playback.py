#
#  Mirage Wallpaper
#
#  Copyright © 2026 王孝慈. All rights reserved.
#

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--derived-data", type=Path, required=True)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    renderer = project.parent / "VideoRenderer/build/release/Tools/VideoWallpaper/VideoWallpaper"
    products = args.derived_data / "Build/Products/Debug"
    app = products / "Mirage Wallpaper.app/Contents"
    library = app / "MacOS/Mirage Wallpaper.debug.dylib"
    with tempfile.TemporaryDirectory(prefix="mirage-shared-video-controller-") as temporary:
        root = Path(temporary)
        fixture = root / "fixture"
        fixture.mkdir()
        (fixture / "project.json").write_text(json.dumps(
            dict(type="video", file="video.mp4", title="Shared controller regression")))
        subprocess.run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                        "-i", "testsrc2=size=320x180:rate=30", "-t", "2", "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", str(fixture / "video.mp4")], check=True)
        executable = root / "SharedVideoPlaybackRegression"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target",
                        f"{platform.machine()}-apple-macos14.2", "-I", str(products),
                        "-F", str(products), "-F", str(products / "PackageFrameworks"),
                        str(project / "Tests/SharedVideoPlaybackRegression.swift"), str(library),
                        "-Xlinker", "-rpath", "-Xlinker", str(app / "MacOS"),
                        "-Xlinker", "-rpath", "-Xlinker", str(app / "Frameworks"),
                        "-o", str(executable)], check=True)
        env = dict(os.environ, LLVM_PROFILE_FILE=str(root / "coverage-%p.profraw"))
        subprocess.run([str(executable), str(fixture), str(renderer)], check=True, timeout=100, env=env)


if __name__ == "__main__":
    main()
