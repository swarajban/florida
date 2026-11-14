import os
from pathlib import Path
import plistlib
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def has_group(entitlements, group):
    groups = entitlements.get('com.apple.security.application-groups')
    return isinstance(groups, list) and group in groups


def validate(app, summary_path=None):
    bundle_id = os.environ['BUNDLE_ID']
    group = f'group.{bundle_id}'
    expected = {'Florida.app': bundle_id,
                'FloridaWidgets.appex': f'{bundle_id}.widgets',
                'FloridaShare.appex': f'{bundle_id}.share'}
    build = os.environ['BUILD_NUMBER']
    versions = {}
    for name, identifier in expected.items():
        bundle = app if name == 'Florida.app' else app / 'PlugIns' / name
        require(bundle.is_dir(), f'Missing archive bundle: {bundle}')
        with (bundle / 'Info.plist').open('rb') as source:
            info = plistlib.load(source)
        require(info.get('CFBundleIdentifier') == identifier, f'{name}: wrong bundle ID')
        version = info.get('CFBundleShortVersionString')
        require(isinstance(version, str) and version.strip(), f'{name}: missing version')
        require(info.get('CFBundleVersion') == build, f'{name}: wrong build; expected {build}')
        versions[name] = (version, build)
        entitlements = plistlib.loads(subprocess.check_output(
            ['codesign', '-d', '--entitlements', '-', '--xml', str(bundle)], stderr=subprocess.PIPE))
        require(has_group(entitlements, group),
                f'{name}: missing archive App Group {group}')
    require(len(set(versions.values())) == 1, 'Archive versions do not match')
    if summary_path is not None:
        with summary_path.open('rb') as source:
            summary = plistlib.load(source)
        require(isinstance(summary, dict) and summary, 'Empty or malformed distribution summary')
        seen = set()
        pending = []
        for items in summary.values():
            require(isinstance(items, list) and items, 'Empty or malformed summary bundle list')
            pending.extend(items)
        while pending:
            item = pending.pop()
            require(isinstance(item, dict), 'Malformed summary bundle')
            children = item.get('embeddedBinaries', [])
            require(isinstance(children, list), 'Malformed embedded bundle list')
            pending.extend(children)
            name = item.get('name')
            require(isinstance(name, str) and name, 'Summary bundle has no name')
            name = Path(name).name
            if not name.endswith(('.app', '.appex')):
                continue
            require(name in expected and name not in seen, f'Unexpected or duplicate bundle: {name}')
            entitlements = item.get('entitlements', {})
            require(entitlements.get('application-identifier') ==
                    f'{os.environ["TEAM_ID"]}.{expected[name]}', f'{name}: wrong exported bundle ID/team')
            require(has_group(entitlements, group),
                    f'{name}: missing exported App Group {group}')
            require((item.get('versionNumber'), item.get('buildNumber')) == versions[name],
                    f'{name}: exported version/build differs from archive')
            seen.add(name)
        require(seen == set(expected), f'Missing exported bundles: {sorted(set(expected) - seen)}')
    print('Verified all three bundle IDs, App Groups and aligned versions/builds'
          + (' in archive and export.' if summary_path is not None else ' in archive.'))


if __name__ == '__main__':
    try:
        require(len(sys.argv) in (2, 3), 'Usage: check-ios-signing.py APP [SUMMARY]')
        validate(Path(sys.argv[1]), Path(sys.argv[2]) if len(sys.argv) == 3 else None)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.CalledProcessError) as error:
        sys.exit(f'::error::Signing validation failed: {error}')
