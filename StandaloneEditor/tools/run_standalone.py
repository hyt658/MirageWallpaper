#!/usr/bin/env python3
# Mirage Wallpaper
# Copyright © 2026 王孝慈. All rights reserved.

"""Run the isolated editor without wallpaper64.exe / 独立启动编辑器。"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import shutil
import urllib.request

ROOT = Path(__file__).resolve().parents[1] / 'runtime'
BASE = ROOT / 'engines/Wine Devel.app/Contents/Resources/wine'
ENV = dict(os.environ, WINEPREFIX=str(ROOT / 'prefix-devel'), WINEARCH='win64',
           WINEDEBUG='fixme-all',
           WINEDLLOVERRIDES='winemenubuilder.exe=d;d3d11,d3d10core=n,b;dxgi,vulkan-1=b',
           DXVK_CONFIG_FILE='Z:' + str(ROOT / 'dxvk.conf'), DXVK_LOG_PATH=str(ROOT / 'logs'), DXVK_LOG_LEVEL='error', MVK_CONFIG_LOG_LEVEL='1',
           VK_DRIVER_FILES=str(BASE / 'lib/wine/x86_64-unix/vulkan/icd.d/MoltenVK_icd.json'),
           MIRAGE_WE_EDITOR_LOADER=str(ROOT / 'Mirage WE Editor.app/Contents/MacOS/wine'),
           DYLD_INSERT_LIBRARIES=str(ROOT / 'MetalInterop.dylib'),
           PATH=str(BASE / 'bin') + ':' + os.environ['PATH'])

def system_language():
    result = subprocess.run(['/usr/bin/defaults', 'read', '-g', 'AppleLanguages'],
                            capture_output=True, text=True, check=True)
    languages = re.findall(r'[a-z]{2,3}(?:-[A-Za-z0-9]+)*', result.stdout)
    available = ROOT / 'windows/WallpaperEngine/locale'
    for language in languages:
        tag = language.lower()
        if tag.startswith('zh'):
            return 'zh-cht' if any(x in tag for x in ('hant', '-tw', '-hk', '-mo')) else 'zh-chs'
        if (available / ('ui_' + tag + '.json')).exists():
            return tag
        matches = sorted(available.glob('ui_' + tag.split('-')[0] + '-*.json'))
        if matches:
            return matches[0].stem[3:]
    return 'en-us'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stop', action='store_true')
    parser.add_argument('--log', default='standalone')
    parser.add_argument('--angle', choices=['d3d11', 'gl'], default='d3d11')
    parser.add_argument('--project', type=Path)
    args = parser.parse_args()
    subprocess.run([str(BASE / 'bin/wineserver'), '-k'], env=ENV, check=False)
    subprocess.run([str(BASE / 'bin/wineserver'), '-w'], env=ENV, check=True, timeout=20)
    descriptor = ROOT / 'bridge-session.json'
    if descriptor.exists():
        try:
            bridge = json.loads(descriptor.read_text())
            request = urllib.request.Request(bridge['endpoint'] + '/shutdown', method='POST',
                                             headers={'Authorization': 'Bearer ' + bridge['token']})
            urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=2).close()
        except Exception:
            pass
        descriptor.unlink(missing_ok=True)
    if args.stop:
        return
    with (ROOT / 'logs/bridge-native.log').open('a') as log:
        bridge_process = subprocess.Popen([str(ROOT / 'Mirage Project Picker.app/Contents/MacOS/ProjectPicker')],
                                          stdout=log, stderr=log, start_new_session=True)
    deadline = time.monotonic() + 5
    while not descriptor.exists():
        if time.monotonic() > deadline or bridge_process.poll() is not None:
            raise RuntimeError('Native project picker did not start / 原生工程选择器启动失败')
        time.sleep(0.05)
    bridge = json.loads(descriptor.read_text())
    ENV['MIRAGE_EDITOR_SESSION_TOKEN'] = bridge['token']
    cache = ROOT / 'windows/WallpaperEngine/ui/uicache/editor/base/Default'
    for name in ['Cache', 'Code Cache']:
        shutil.rmtree(cache / name, ignore_errors=True)
    locale = system_language()
    session = {'language': locale, 'bridge': bridge, 'defaults': json.loads((ROOT / 'standalone-defaults.json').read_text()),
               'project': 'Z:' + str(args.project.resolve()) if args.project else None}
    (ROOT / 'windows/WallpaperEngine/ui/dist/scripts/mirage-session.js').write_text(
        '// Copyright © 2026 王孝慈. All rights reserved.\nwindow.mirageEditorSession = ' + json.dumps(session, ensure_ascii=False) + ';\n')
    argv = [str(BASE / 'bin/wine'), r'M:\WallpaperEngine\bin\wallpaperui.exe',
            '-weuimain', '-window', 'editor', '-buildv', '20000800000042',
            '-skin', 'mirage', '-language', locale, '-steamlanguage', locale,
            '--in-process-gpu', '--disable-gpu-driver-bug-workarounds', '--use-cmd-decoder=validating', '--use-angle=' + args.angle, '--disable-software-rasterizer',
            '--disable-direct-composition', '--ignore-gpu-blocklist', '--enable-gpu-rasterization',
            '--disable-background-networking', '--disable-component-update', '--disable-sync',
            '--disable-features=CalculateNativeWinOcclusion,RemoveRedirectionBitmap']
    with (ROOT / 'logs' / (args.log + '.log')).open('w') as log:
        process = subprocess.Popen(argv, env=ENV, cwd=ROOT / 'windows/WallpaperEngine/bin',
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    print(json.dumps({'pid': process.pid, 'language': locale}))

if __name__ == '__main__':
    main()
