#!/usr/bin/env python3
"""Check packaged iOS permission descriptions before a TestFlight upload."""
import argparse
import pathlib
import plistlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=pathlib.Path)
args = parser.parse_args()
info = plistlib.loads((args.app / 'Info.plist').read_bytes())
required = ['NSMicrophoneUsageDescription']
if (args.app / 'Frameworks/WebRTC.framework').is_dir():
    # Apple's static scanner flags the bundled camera API references even when
    # the app only creates audio tracks. This does not enable camera access.
    required.append('NSCameraUsageDescription')
for key in required:
    if not isinstance(info.get(key), str) or not info[key].strip():
        raise SystemExit(f'Missing packaged purpose string: {key}')
for language in ['de', 'en']:
    strings = plistlib.loads((args.app / f'{language}.lproj/InfoPlist.strings').read_bytes())
    for key in required:
        if not isinstance(strings.get(key), str) or not strings[key].strip():
            raise SystemExit(f'Missing {language} packaged purpose string: {key}')
print('Packaged purpose strings verified:', ', '.join(required))
print('Packaged version:', info['CFBundleShortVersionString'], 'build', info['CFBundleVersion'])
