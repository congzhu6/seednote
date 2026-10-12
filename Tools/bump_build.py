#!/usr/bin/env python3
"""Increase the build number before uploading to App Store Connect, which rejects a
build number it has already received for the same version.

  python3 Tools/bump_build.py                  # 0.1.0 (1) -> 0.1.0 (2)
  python3 Tools/bump_build.py --version 0.2.0  # -> 0.2.0 (3)

The project generator preserves both values, so regenerating does not reset them."""
from pathlib import Path
import argparse, re

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--version', help='Also set the user-visible version, e.g. 0.2.0')
args = parser.parse_args()
project = Path(__file__).resolve().parents[1]/'Seednote.xcodeproj'/'project.pbxproj'
text = project.read_text()

builds = {int(value) for value in re.findall(r'"CURRENT_PROJECT_VERSION" = "(\d+)";', text)}
if not builds:
    raise SystemExit('CURRENT_PROJECT_VERSION not found in project.pbxproj')
build = max(builds) + 1
text = re.sub(r'"CURRENT_PROJECT_VERSION" = "\d+";', f'"CURRENT_PROJECT_VERSION" = "{build}";', text)
if args.version:
    if not re.fullmatch(r'\d+(\.\d+){0,2}', args.version):
        raise SystemExit('Version must look like 1, 1.2 or 1.2.3')
    text = re.sub(r'"MARKETING_VERSION" = "[^"]*";', f'"MARKETING_VERSION" = "{args.version}";', text)
project.write_text(text)
version = re.search(r'"MARKETING_VERSION" = "([^"]*)";', text).group(1)
print(f'Seednote {version} ({build})')
