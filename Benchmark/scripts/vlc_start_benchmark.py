#!/usr/bin/env python3
"""VLCKit start benchmark: 3.7.4 against 4.0.0a18 through one host app (Benchmark/README.md).

  build   [--side 374,400a18] [--platform ios,tvos] [--device]
  run     [--platform ios,tvos] [--rounds 20] [--warmup 1] [--set S1] [--correctness]
          [--start-by ISO-UTC] [--deadline ISO-UTC] [--allow-busy]
  report  <run folder>... [--csv FILE]
  sizes   app sizes from the --device builds

Every command takes --wuwtv <wuwtv task worktree>: it provides scripts/agent_build.sh (builds, locks) and
release_tests.load_playlist_profile. `run` works only inside `scripts/agent_build.sh locked`, on its own simulators
(`WUWTV Benchmark VLC iPhone` / `WUWTV Benchmark VLC Apple TV`), which it creates and deletes. The stream addresses
reach only the app's data container (0600) and leave with the app. Results hold aliases and numbers only, in
~/Library/Developer/WUWTV-vlc-start-benchmark/.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
import plistlib
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit

HERE = Path(__file__).resolve().parent
BENCHMARK = HERE.parent
PROJECT = BENCHMARK / 'VLCStartBenchmark.xcodeproj'
APP_SOURCES = BENCHMARK / 'App'
SCHEME = 'VLCStartBenchmark'
OUTPUT = Path('~/Library/Developer/WUWTV-vlc-start-benchmark').expanduser()
BUILDS = OUTPUT / 'builds'
STREAMS = Path('~/.private_keys/wuwtv/player-benchmark-streams.json').expanduser()
DERIVED_ROOT = Path('~/Library/Developer/Xcode/DerivedData').expanduser()
QUEUE = DERIVED_ROOT / 'WUWTV-agent-queue'
VLCUI_URL = 'https://github.com/yucelokan/VLCUI.git'
VLCKIT_SPM_URL = 'https://github.com/yucelokan/vlckit-spm.git'
CPU_BUDGET = 70
IDLE_CPU = 20
RESULT_LINE = 'VLC start benchmark:'


@dataclass(frozen=True)
class Side:
    key: str
    label: str
    vlcui: str
    vlckit_spm_branch: str
    vlckit_spm: str
    libvlc_prefix: str
    # libvlc_get_changeset() of the side's VLCKit binary (`strings` on the framework shows the same value). The
    # framework's own CFBundleShortVersionString is a placeholder ("1.0") and proves nothing.
    libvlc_changeset: str

    @property
    def product(self):
        return f'VLCStartBenchmark{self.key}'

    @property
    def bundle_id(self):
        return f'com.wuwtv.benchmark.vlc{self.key}'


@dataclass(frozen=True)
class Platform:
    key: str
    os_name: str
    simulator_sdk: str
    device_sdk: str
    release_device: str
    benchmark_device: str
    alias: str


SIDES = {
    '374': Side('374', '3.7.4', 'bd16de8c6158026739b14a8b58abeb9e7e433357', 'vlc372',
                '0fa85a10652d9a6292384ef9a778422130f62c2b', '3.0.24', '3.0.24-42-gcdceca9c6f'),
    '400a18': Side('400a18', '4.0.0a18', '27ea0f20401a0832f4be844ab4efae18d1ea3793', 'vlckit-4.0',
                   '772ddbea600fc7ac80d1782ed3ebe019850dd9fe', '4.0.0', '4.0.0-dev-35511-ga9e2f402ca'),
}
# The order of the alternation: A B B A ...
SIDE_ORDER = ('374', '400a18')
PLATFORMS = {
    'ios': Platform('ios', 'iOS', 'iphonesimulator', 'iphoneos', 'WUWTV Release iPhone', 'WUWTV Benchmark VLC iPhone', 'S-IPHONE'),
    'tvos': Platform('tvos', 'tvOS', 'appletvsimulator', 'appletvos', 'WUWTV Release Apple TV', 'WUWTV Benchmark VLC Apple TV', 'S-TV'),
}
BENCHMARK_DEVICES = frozenset(platform.benchmark_device for platform in PLATFORMS.values())
BENCHMARK_BUNDLES = frozenset(side.bundle_id for side in SIDES.values())
# One round, as the matrix defines it: L1 start, Next to L2, Previous to L1, M1 start, E1 start.
STEPS = (('L1', 'start'), ('L2', 'next'), ('L1', 'previous'), ('M1', 'start'), ('E1', 'start'))
TIMING = {'failAfterSeconds': 20, 'holdSeconds': 5, 'settleSeconds': 2, 'idleBeforeFirstSeconds': 2}
CSV_FIELDS = ['platform', 'device', 'side', 'label', 'round', 'order', 'alias', 'action', 'outcome', 'motion_ms',
              'clock_start_ms', 'playing_ms', 'error_ms', 'first_tick_ms', 'first_tick_media_ms', 'motion_media_ms',
              'buffering_in_hold', 'error_in_hold', 'max_advance_gap_ms', 'tick_interval_p50_ms', 'hold_ms',
              'footprint_steady_mib', 'footprint_peak_mib', 'video_width', 'video_height', 'states', 'vlcui_states']


class Refused(RuntimeError):
    """A guard stopped an action: nothing was changed."""


def terminate_as_exit(signum, _frame):
    """agent_run.sh stops a stalled run with SIGTERM. Python's default would skip every `finally`, leaving the
    apps, which hold the stream addresses, on the benchmark simulator."""
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise SystemExit(128 + signum)


# MARK: - Inputs

def private_file(path):
    path = Path(path).expanduser().resolve()
    if path.is_relative_to(BENCHMARK.parent) or path.stat().st_mode & 0o077:
        raise Refused(f'Keep {path.name} outside the repository with permissions 0600')
    return path


def linked_worktree(path):
    """The wuwtv task worktree. The primary checkout is refused: its branch moves with the release line."""
    path = Path(path).expanduser().resolve()
    git_dir = subprocess.run(['git', '-C', str(path), 'rev-parse', '--absolute-git-dir'], capture_output=True, text=True)
    common = subprocess.run(['git', '-C', str(path), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True)
    if git_dir.returncode or common.returncode:
        raise Refused(f'{path} is not a git checkout')
    if Path(git_dir.stdout.strip()).resolve() == Path(common.stdout.strip()).resolve():
        raise Refused(f'{path} is a primary checkout; pass the wuwtv task worktree')
    if not (path / 'scripts/agent_build.sh').exists() or not (path / 'scripts/release_tests.py').exists():
        raise Refused(f'{path} has no scripts/agent_build.sh and scripts/release_tests.py')
    return path


def load_playlist_profile_function(wuwtv):
    """release_tests.load_playlist_profile, imported by path (it checks 0600 and a location outside the repository)."""
    spec = importlib.util.spec_from_file_location('wuwtv_release_tests', wuwtv / 'scripts/release_tests.py')
    module = importlib.util.module_from_spec(spec)
    # Its dataclasses look their module up in sys.modules while it loads.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.load_playlist_profile


def load_stream_set(name, streams=STREAMS):
    sets = json.loads(private_file(streams).read_text())['sets']
    if name not in sets:
        raise Refused(f'No stream set {name}; the map has {", ".join(sorted(sets))}')
    return sets[name]


def encode_segment(value):
    """NetworkKit's XtreamURL.encodeSegment: unreserved characters only; a standalone dot is never navigation."""
    if value in ('.', '..'):
        return value.replace('.', '%2E')
    return quote(value, safe='-._~')


def stream_urls(stream_set, profile):
    """The addresses the app plays for a `get.php` profile (NetworkKit `XtreamURL.mediaURLString`): live as `.ts`,
    the movie and the episode with their container extension."""
    url = urlsplit(profile['playlistURL'])
    query = parse_qs(url.query)
    try:
        username, password = query['username'][0], query['password'][0]
    except (KeyError, IndexError):
        raise Refused('The profile is not an Xtream get.php address') from None
    base = f'{url.scheme}://{url.netloc}{url.path.rsplit("/", 1)[0]}'

    def media(kind, resource):
        return base + '/' + '/'.join(encode_segment(part) for part in (kind, username, password, resource))

    return {
        'L1': media('live', f"{stream_set['L1']['stream_id']}.ts"),
        'L2': media('live', f"{stream_set['L2']['stream_id']}.ts"),
        'M1': media('movie', f"{stream_set['M1']['stream_id']}.{stream_set['M1']['container']}"),
        'E1': media('series', f"{stream_set['E1']['episode_id']}.{stream_set['E1']['container']}"),
    }


def secrets_of(profile, urls):
    url = urlsplit(profile['playlistURL'])
    query = parse_qs(url.query)
    values = {profile['playlistURL'], url.netloc, url.hostname or ''} | set(urls.values())
    for key in ('username', 'password'):
        values.update(query.get(key, []))
    values |= {quote(value, safe='') for value in set(values)}
    return {value for value in values if len(value) >= 3}


def assert_shareable(text, secrets):
    """Results leave the Mac: no address, host, account or stream address may be in them."""
    if re.search(r'https?://', text, re.IGNORECASE) or any(secret in text for secret in secrets):
        raise Refused('A result record would contain an address or credential; nothing was written')
    return text


def write_private(path, text):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        file.write(text)
    os.chmod(path, 0o600)
    return Path(path)


def plan(side, label, round_number, urls):
    return {'version': 1, 'side': side.key, 'label': label, 'round': round_number, **TIMING,
            'steps': [{'alias': alias, 'action': action, 'url': urls[alias]} for alias, action in STEPS]}


def schedule(rounds, warmup, correctness=False, order=SIDE_ORDER):
    """Warm-up rounds first (one per side, labelled and never measured), then A B B A ...: anything that drifts over
    the run (provider, CDN, the Mac's temperature, caches) lands on both sides alike."""
    if correctness:
        return [('correctness', 1, side) for side in order]
    entries = [('warmup', number + 1, side) for number in range(warmup) for side in order]
    counts = dict.fromkeys(order, 0)
    pattern = (order[0], order[1], order[1], order[0])
    for index in range(2 * rounds):
        side = pattern[index % 4]
        counts[side] += 1
        entries.append(('measure', counts[side], side))
    return entries


# MARK: - Build

def derived_data_name():
    """agent_build.sh's rule for a linked worktree: WUWTV-agent-wt-<folder>, here for this VLCUI checkout."""
    top = Path(subprocess.check_output(['git', '-C', str(BENCHMARK), 'rev-parse', '--show-toplevel'], text=True).strip())
    git_dir = subprocess.check_output(['git', '-C', str(top), 'rev-parse', '--absolute-git-dir'], text=True).strip()
    common = subprocess.check_output(['git', '-C', str(top), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                     text=True).strip()
    if Path(git_dir).resolve() == Path(common).resolve():
        return 'WUWTV-agent-vlcui'
    return 'WUWTV-agent-wt-' + re.sub(r'[^A-Za-z0-9._-]', '-', top.name)


def agent_environment():
    return {**os.environ, 'WUWTV_AGENT_DERIVED_DATA': str(DERIVED_ROOT / derived_data_name())}


def resolved_file(project):
    return Path(project) / 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved'


def package_resolved(side):
    return {'pins': [
        {'identity': 'vlckit-spm', 'kind': 'remoteSourceControl', 'location': VLCKIT_SPM_URL,
         'state': {'branch': side.vlckit_spm_branch, 'revision': side.vlckit_spm}},
        {'identity': 'vlcui', 'kind': 'remoteSourceControl', 'location': VLCUI_URL, 'state': {'revision': side.vlcui}},
    ], 'version': 2}


def prepare_copy(side, folder):
    """A temporary copy of the project for one side: VLCUI pinned by revision, and a Package.resolved that pins
    vlckit-spm too (VLCUI pulls it by branch, which would otherwise float)."""
    folder = Path(folder)
    project = folder / PROJECT.name
    shutil.copytree(PROJECT, project, ignore=shutil.ignore_patterns('xcuserdata', 'swiftpm'))
    shutil.copytree(APP_SOURCES, folder / APP_SOURCES.name, ignore=shutil.ignore_patterns('.*'))
    pbxproj = project / 'project.pbxproj'
    text = pbxproj.read_text()
    text, pins = re.subn(r'(repositoryURL = "' + re.escape(VLCUI_URL) + r'";\s*requirement = \{\s*kind = revision;\s*'
                         r'revision = )[0-9a-f]{40}(;)', rf'\g<1>{side.vlcui}\g<2>', text)
    text, suffixes = re.subn(r'WUW_BENCHMARK_SUFFIX = [0-9a-z]+;', f'WUW_BENCHMARK_SUFFIX = {side.key};', text)
    if pins != 1 or suffixes != 2:
        raise Refused('The benchmark project no longer has one VLCUI revision pin and two product suffixes')
    pbxproj.write_text(text)
    resolved = resolved_file(project)
    resolved.parent.mkdir(parents=True)
    resolved.write_text(json.dumps(package_resolved(side), indent=2) + '\n')
    return project


def resolved_pins(path):
    return {pin['identity']: pin['state'].get('revision') for pin in json.loads(Path(path).read_text())['pins']}


def verify_pins(pins, side):
    expected = {'vlcui': side.vlcui, 'vlckit-spm': side.vlckit_spm}
    if pins != expected:
        raise Refused(f'{side.label}: resolved {pins}, expected {expected}')
    return pins


def checkout_revisions(derived_data):
    revisions = {}
    for identity, folder in (('vlcui', 'VLCUI'), ('vlckit-spm', 'vlckit-spm')):
        result = subprocess.run(['git', '-C', str(Path(derived_data) / 'SourcePackages/checkouts' / folder), 'rev-parse', 'HEAD'],
                                capture_output=True, text=True)
        revisions[identity] = result.stdout.strip() if result.returncode == 0 else None
    return revisions


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as file:
        for block in iter(lambda: file.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def tree_bytes(path):
    return sum(file.stat().st_size for file in Path(path).rglob('*') if file.is_file() and not file.is_symlink())


def framework_info(app):
    frameworks = {}
    for framework in sorted((Path(app) / 'Frameworks').glob('*.framework')):
        info = plistlib.loads((framework / 'Info.plist').read_bytes()) if (framework / 'Info.plist').exists() else {}
        binary = framework / info.get('CFBundleExecutable', framework.stem)
        frameworks[framework.name] = {'version': info.get('CFBundleShortVersionString'),
                                      'bundle_version': info.get('CFBundleVersion'),
                                      'binary_bytes': binary.stat().st_size if binary.exists() else None,
                                      'bytes': tree_bytes(framework)}
    return frameworks


def app_sizes(app):
    """The Release device app: bundle, executable, frameworks, and the bundle zipped (close to the download)."""
    app = Path(app)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    with tempfile.TemporaryDirectory(prefix='vlc-start-benchmark-size-') as folder:
        archive = Path(folder) / 'app.zip'
        subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True)
        zipped = archive.stat().st_size
    return {'bundle_bytes': tree_bytes(app), 'zipped_bytes': zipped,
            'executable_bytes': (app / info['CFBundleExecutable']).stat().st_size}


def tool_versions():
    def output(command):
        result = subprocess.run(command, capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None
    return {'xcode': ' '.join((output(['xcodebuild', '-version']) or '').split()), 'macos': output(['sw_vers', '-productVersion']),
            'host': output(['sysctl', '-n', 'hw.model']),
            'sdks': {sdk: output(['xcrun', '--sdk', sdk, '--show-sdk-version'])
                     for sdk in ('iphonesimulator', 'iphoneos', 'appletvsimulator', 'appletvos')}}


def build_record_path(side, platform, kind):
    return BUILDS / f'{side.key}-{platform.key}-{kind}.json'


def build_one(wuwtv, side, platform, device):
    kind = 'device' if device else 'simulator'
    sdk = platform.device_sdk if device else platform.simulator_sdk
    destination = f'generic/platform={platform.os_name}' + ('' if device else ' Simulator')
    agent_build = str(wuwtv / 'scripts/agent_build.sh')
    environment = agent_environment()
    derived_data = Path(subprocess.check_output([agent_build, 'path'], text=True, env=environment).strip())
    # A failed build must not leave an older app usable under this side's name.
    build_record_path(side, platform, kind).unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix='vlc-start-benchmark-') as folder:
        project = prepare_copy(side, folder)
        command = [agent_build, 'build', '-project', str(project), '-scheme', SCHEME, '-configuration', 'Release',
                   '-destination', destination, '-onlyUsePackageVersionsFromResolvedFile', 'ARCHS=arm64']
        if device:
            command.append('CODE_SIGNING_ALLOWED=NO')
        print(f'{RESULT_LINE} building {side.label} for {platform.os_name} ({kind})', flush=True)
        status = subprocess.call(command, env=environment)
        app = derived_data / f'Build/Products/Release-{sdk}/{side.product}.app'
        if status:
            raise Refused(f'{side.label} {platform.key} {kind}: xcodebuild exit {status}')
        # The resolution the build used, checked twice: the resolved file, and the checkouts it built. A mismatch
        # discards the app, so `run` cannot use it.
        resolved = resolved_file(project)
        try:
            pins = verify_pins(resolved_pins(resolved), side)
            checkouts = checkout_revisions(derived_data)
            if checkouts != pins:
                raise Refused(f'{side.label}: the package checkouts are {checkouts}, the resolved file pins {pins}')
        except Refused:
            shutil.rmtree(app, ignore_errors=True)
            build_record_path(side, platform, kind).unlink(missing_ok=True)
            raise
        BUILDS.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(resolved, build_record_path(side, platform, kind).with_suffix('.Package.resolved'))
    built = app
    info = plistlib.loads((built / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != side.bundle_id:
        raise Refused(f'{built.name} has bundle id {info.get("CFBundleIdentifier")}, expected {side.bundle_id}')
    # Xcode removes the other side's app from Build/Products as a stale output of the same target, so each app is kept
    # in its own folder outside DerivedData; `run` installs from there.
    app = keep_app(built, side, platform, kind)
    record = {'side': side.key, 'label': side.label, 'platform': platform.key, 'kind': kind, 'app': str(app),
              'bundle_id': side.bundle_id, 'executable_sha256': sha256(app / info['CFBundleExecutable']),
              'pins': pins, 'package_resolved': json.loads(resolved_path_text(side, platform, kind)),
              'frameworks': framework_info(app), 'tools': tool_versions(),
              'built': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')}
    if device:
        record['sizes'] = app_sizes(app)
    build_record_path(side, platform, kind).write_text(json.dumps(record, indent=2) + '\n')
    print(f'{RESULT_LINE} built {side.label} {platform.key} {kind}: VLCUI {pins["vlcui"][:8]}, '
          f'vlckit-spm {pins["vlckit-spm"][:8]}', flush=True)
    return record


def keep_app(built, side, platform, kind):
    folder = BUILDS / 'apps' / f'{side.key}-{platform.key}-{kind}'
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, mode=0o700)
    subprocess.run(['ditto', str(built), str(folder / built.name)], check=True)
    return folder / built.name


def resolved_path_text(side, platform, kind):
    return build_record_path(side, platform, kind).with_suffix('.Package.resolved').read_text()


def build(args):
    if os.environ.get('WUWTV_AGENT_BUILD_LOCK_HELD') == '1':
        raise Refused('build runs outside `agent_build.sh locked`; it takes its own build slot')
    for platform in args.platforms:
        for side in args.sides:
            build_one(args.wuwtv, side, platform, args.device)
    return 0


# MARK: - Simulators (benchmark devices only)

def simctl(*arguments, check=True):
    return subprocess.run(['xcrun', 'simctl', *arguments], capture_output=True, text=True, check=check)


def devices():
    listing = json.loads(simctl('list', 'devices', '-j').stdout)['devices']
    return [{**device, 'runtime': runtime} for runtime, entries in listing.items() for device in entries]


def device_name(udid):
    for device in devices():
        if device['udid'] == udid:
            return device['name']
    return None


def require_benchmark_device(udid):
    """Every removal names its device first: only the benchmark's own simulators are ever changed."""
    name = device_name(udid)
    if name not in BENCHMARK_DEVICES:
        raise Refused(f'Refusing to change simulator {udid} ({name}): not a benchmark device')
    return name


def remove_app(udid, bundle_id, attempts=5):
    require_benchmark_device(udid)
    if bundle_id not in BENCHMARK_BUNDLES:
        raise Refused(f'Refusing to remove {bundle_id}: not a benchmark app')
    for _ in range(attempts):
        simctl('terminate', udid, bundle_id, check=False)
        simctl('uninstall', udid, bundle_id, check=False)
        if simctl('get_app_container', udid, bundle_id, check=False).returncode:
            return True
        time.sleep(2)
    return False


def delete_device(udid):
    require_benchmark_device(udid)
    simctl('shutdown', udid, check=False)
    require_benchmark_device(udid)
    simctl('delete', udid, check=False)
    return device_name(udid) is None


def remove_leftovers(platform):
    """A stopped run can leave its device behind: its apps go first, then the device."""
    removed = []
    for device in devices():
        if device['name'] == platform.benchmark_device:
            if device['state'] == 'Booted':
                for bundle_id in sorted(BENCHMARK_BUNDLES):
                    remove_app(device['udid'], bundle_id, attempts=2)
            # Deleting the device deletes its apps and their data with it.
            delete_device(device['udid'])
            removed.append(device['udid'])
    return removed


def create_device(platform):
    """The benchmark device copies the device type and runtime of the matching `WUWTV Release` simulator."""
    for device in devices():
        if device['name'] == platform.release_device and device.get('isAvailable'):
            udid = simctl('create', platform.benchmark_device, device['deviceTypeIdentifier'], device['runtime']).stdout.strip()
            return {'udid': udid, 'name': platform.benchmark_device,
                    'model': device['deviceTypeIdentifier'].rsplit('.', 1)[-1],
                    'os': device['runtime'].rsplit('.', 1)[-1]}
    raise Refused(f'No available {platform.release_device} simulator to copy')


def app_container(udid, bundle_id):
    return Path(simctl('get_app_container', udid, bundle_id, 'data').stdout.strip())


# MARK: - Load and queue

def cpu_busy_percent(samples=2, interval=1):
    """User plus system CPU, as agent_build.sh measures it: 100 minus top's idle in the last sample."""
    output = subprocess.run(['top', '-l', str(samples), '-n', '0', '-s', str(interval)], capture_output=True, text=True).stdout
    idle = re.findall(r'CPU usage: .*?([\d.]+)% idle', output)
    return [round(100 - float(value), 1) for value in idle]


def idle_check():
    """The start condition: total CPU under 20 % over 30 s (six 5-second samples after top's first)."""
    samples = cpu_busy_percent(samples=7, interval=5)[1:]
    return {'samples': samples, 'mean': round(statistics.mean(samples), 1) if samples else None}


def wait_for_idle(attempts=6, pause=20, check=idle_check):
    """A just-booted simulator settles for a while: the check is repeated a few times, each one recorded."""
    records = []
    for attempt in range(attempts):
        records.append(check())
        if records[-1]['mean'] is not None and records[-1]['mean'] < IDLE_CPU:
            break
        if attempt + 1 < attempts:
            time.sleep(pause)
    return records


class CPUMonitor:
    """This run's own CPU record (never an earlier run's line): a sample every 15 s while the run holds the queue."""

    def __init__(self, interval=15):
        self.interval = interval
        self.samples = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._watch, daemon=True)

    def _watch(self):
        while not self._stop.is_set():
            values = cpu_busy_percent()
            if values:
                self.samples.append((time.time(), values[-1]))
            self._stop.wait(self.interval)

    def start(self):
        self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=10)
        return self.summary()

    def summary(self, budget=CPU_BUDGET):
        if not self.samples:
            return {'samples': 0, 'peak': None, 'seconds_over_budget': None}
        over = 0
        for index, (at, value) in enumerate(self.samples):
            if value > budget:
                over += (self.samples[index + 1][0] - at) if index + 1 < len(self.samples) else self.interval
        return {'samples': len(self.samples), 'peak': max(value for _, value in self.samples),
                'mean': round(statistics.mean(value for _, value in self.samples), 1),
                'seconds_over_budget': round(over), 'budget': budget,
                'series': [[dt.datetime.fromtimestamp(at, dt.timezone.utc).isoformat(timespec='seconds'), value]
                           for at, value in self.samples]}


def ancestors(pid=None):
    pid, chain = pid or os.getpid(), set()
    while pid and pid not in chain and pid > 1:
        chain.add(pid)
        result = subprocess.run(['ps', '-o', 'ppid=', '-p', str(pid)], capture_output=True, text=True)
        pid = int(result.stdout.strip() or 0)
    return chain


def queue_holders(queue=QUEUE, own=None):
    """Live holders of agent_build.sh's machine-wide locks other than this run's own `locked`."""
    own = ancestors() if own is None else own
    holders = []
    for lock in sorted(Path(queue).glob('*.lock')):
        try:
            pid = int((lock / 'pid').read_text().strip())
        except (OSError, ValueError):
            continue
        if pid not in own and subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode == 0:
            holders.append({'lock': lock.name, 'pid': pid})
    return holders


# MARK: - Library check

def check_library(side, report):
    """The engine the app loaded must be the side's: libVLC 3.0.24 for 3.7.4, the 4.0.0 build of 4.0.0a18, each
    identified by its changeset."""
    version = report.get('libvlcVersion') or ''
    changeset = report.get('libvlcChangeset')
    if not version.startswith(side.libvlc_prefix):
        raise Refused(f'{side.label}: the app loaded libVLC {version or "unknown"}, expected {side.libvlc_prefix}')
    if changeset != side.libvlc_changeset:
        raise Refused(f'{side.label}: the app loaded libVLC changeset {changeset}, expected {side.libvlc_changeset}')
    if report.get('bundleID') != side.bundle_id:
        raise Refused(f'{side.label}: the result came from {report.get("bundleID")}')
    return True


# MARK: - Run

def launch_round(device, side, label, round_number, urls, secrets, emit, timeout=None):
    """One launch of one side's app for one round. Returns its library report and samples."""
    udid = device['udid']
    documents = app_container(udid, side.bundle_id) / 'Documents'
    documents.mkdir(parents=True, exist_ok=True)
    results = documents / 'results.jsonl'
    plan_path = documents / 'plan.json'
    results.unlink(missing_ok=True)
    write_private(plan_path, json.dumps(plan(side, label, round_number, urls)))
    timeout = timeout or launch_budget()
    library, samples, done, offset, exited = None, [], False, 0, False
    try:
        launched = simctl('launch', '--terminate-running-process', udid, side.bundle_id, check=False)
        if launched.returncode:
            print(f'{side.label}: the app did not launch (simctl exit {launched.returncode})', flush=True)
            timeout = 0
        # A simulator app is a process on the Mac: `simctl launch` prints "<bundle id>: <pid>".
        pid = re.search(r':\s*(\d+)\s*$', launched.stdout or '')
        ends = time.monotonic() + timeout
        while time.monotonic() < ends and not done and not exited:
            time.sleep(0.5)
            # One more read after the app has gone: it may have written its last lines just before.
            exited = bool(pid) and not process_alive(int(pid.group(1)))
            if not results.exists():
                continue
            text = results.read_text()
            end = text.rfind('\n') + 1
            complete, offset = text[offset:end], max(offset, end)
            for line in complete.splitlines():
                event = json.loads(line)
                assert_shareable(line, secrets)
                if event['event'] == 'library':
                    check_library(side, event)
                    library = event
                elif event['event'] == 'sample':
                    if library is None:
                        raise Refused(f'{side.label}: a sample came before the library report')
                    samples.append(event)
                    emit(event)
                elif event['event'] == 'done':
                    done = True
                elif event['event'] == 'aborted':
                    raise Refused(f'{side.label}: the app aborted the round ({event.get("reason")})')
    finally:
        simctl('terminate', udid, side.bundle_id, check=False)
        plan_path.unlink(missing_ok=True)
        results.unlink(missing_ok=True)
    if exited and not done:
        print(f'{side.label}: the app exited before it finished the round', flush=True)
    for alias, action in STEPS[len(samples):]:
        samples.append({'event': 'sample', 'side': side.key, 'label': label, 'round': round_number, 'alias': alias,
                        'action': action, 'outcome': 'no_result', 'bufferingInHold': 0, 'errorInHold': False, 'states': ''})
        emit(samples[-1])
    return library, samples


def process_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def sample_line(platform, event):
    """One printed line per measurement: aliases and numbers."""
    def number(key, scale=1, unit='ms'):
        value = event.get(key)
        return f'{value / scale:.0f} {unit}' if isinstance(value, (int, float)) else '-'
    return (f"{platform.key:4} {SIDES[event['side']].label:8} {event['label']:11} r{event['round']:02} {event['alias']} "
            f"{event['action']:8} {event['outcome']:9} motion {number('motionMs'):>8} playing {number('playingMs'):>8} "
            f"buffering {event.get('bufferingInHold', 0)} peak {number('footprintPeakBytes', 1048576, 'MiB')}")


def parse_time(value):
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00')) if value else None


def launch_budget():
    return TIMING['idleBeforeFirstSeconds'] + 30 + len(STEPS) * (
        TIMING['failAfterSeconds'] + TIMING['holdSeconds'] + TIMING['settleSeconds'])


def run_platform(platform, builds, urls, secrets, args, folder, records):
    """One platform: its own device, both apps, the CPU start condition, then the rounds."""
    record = {'platform': platform.key, 'device': platform.alias}
    records.append(record)
    samples = []
    device = None
    removed = remove_leftovers(platform)
    record['leftover_devices_removed'] = len(removed)
    try:
        device = create_device(platform)
        record.update(model=device['model'], os=device['os'])
        simctl('boot', device['udid'])
        simctl('bootstatus', device['udid'], '-b')
        for side in args.sides:
            app = Path(builds[side.key]['app'])
            simctl('install', device['udid'], str(app))
        time.sleep(10)
        record['queue_holders'] = queue_holders()
        record['booted_simulators'] = sum(1 for entry in devices() if entry['state'] == 'Booted')
        record['cpu_checks'] = wait_for_idle(attempts=1 if args.allow_busy else 6)
        record['cpu_before'] = record['cpu_checks'][-1]
        print(f"{platform.key}: CPU {record['cpu_before']['mean']} % over 30 s before the first sample; "
              f"other queue holders: {len(record['queue_holders'])}", flush=True)
        if not args.allow_busy and (record['queue_holders'] or (record['cpu_before']['mean'] or 100) >= IDLE_CPU):
            raise Refused(f'{platform.key}: the Mac is not idle (CPU under {IDLE_CPU} % and no other queue holder needed)')
        record['started'] = now_iso()
        entries = schedule(args.rounds, args.warmup, args.correctness, order=tuple(side.key for side in args.sides))
        record['schedule'] = [f'{label}:{round_number}:{side}' for label, round_number, side in entries]
        for index, (label, round_number, side_key) in enumerate(entries):
            if args.deadline and dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=launch_budget()) > args.deadline:
                record['stopped_at_deadline'] = f'{label}:{round_number}:{side_key}'
                print(f'{platform.key}: stopping before {label} {round_number} {side_key}: the deadline would pass', flush=True)
                break
            side = SIDES[side_key]
            library, round_samples = launch_round(device, side, label, round_number, urls, secrets,
                                                  lambda event: print(sample_line(platform, event), flush=True))
            if library:
                record.setdefault('libraries', {})[side.key] = {key: library.get(key) for key in (
                    'libvlcVersion', 'libvlcChangeset', 'vlckitVersion', 'bundleID', 'idleFootprintBytes', 'options')}
            for sample in round_samples:
                sample.update(platform=platform.key, device=platform.alias, order=index)
            samples += round_samples
    finally:
        record['finished'] = now_iso()
        if device:
            record['apps_removed'] = all(remove_app(device['udid'], side.bundle_id) for side in args.sides)
            record['device_removed'] = delete_device(device['udid'])
        with open(folder / 'samples.jsonl', 'a') as file:
            for sample in samples:
                file.write(assert_shareable(json.dumps(sample, sort_keys=True), secrets) + '\n')
    return record, samples


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')


def run(args):
    if os.environ.get('WUWTV_AGENT_BUILD_LOCK_HELD') != '1':
        raise Refused('run works only inside the queue: scripts/agent_build.sh locked python3 ... run ...')
    signal.signal(signal.SIGTERM, terminate_as_exit)
    if args.start_by and dt.datetime.now(dt.timezone.utc) > args.start_by:
        raise Refused(f'Past the latest start ({args.start_by.isoformat()}): the window moves to its fallback')
    stream_set = load_stream_set(args.set)
    profile = args.load_profile(STREAMS.parent / stream_set['profile_file'])
    urls = stream_urls(stream_set, profile)
    secrets = secrets_of(profile, urls)
    builds = {}
    for platform in args.platforms:
        for side in args.sides:
            path = build_record_path(side, platform, 'simulator')
            if not path.exists():
                raise Refused(f'No {side.label} {platform.key} simulator build: run `build` first')
            record = json.loads(path.read_text())
            verify_pins(record['pins'], side)
            app = Path(record['app'])
            info = plistlib.loads((app / 'Info.plist').read_bytes())
            if sha256(app / info['CFBundleExecutable']) != record['executable_sha256']:
                raise Refused(f'{app.name} changed since its build record; build it again')
            builds.setdefault(platform.key, {})[side.key] = record
    label = 'correctness' if args.correctness else 'measure'
    folder = OUTPUT / f"{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}-{label}"
    folder.mkdir(parents=True, mode=0o700)
    environment = {'method': 'Benchmark/README.md', 'set': args.set, 'rounds': args.rounds, 'warmup': args.warmup,
                   'correctness': args.correctness, 'timing': TIMING, 'steps': [f'{a} {b}' for a, b in STEPS],
                   'tools': tool_versions(), 'commit': git_head(), 'started': now_iso(),
                   'start_by': args.start_by.isoformat() if args.start_by else None,
                   'deadline': args.deadline.isoformat() if args.deadline else None,
                   'builds': {key: {side: {field: record[field] for field in ('pins', 'frameworks', 'executable_sha256', 'built')}
                                    for side, record in value.items()} for key, value in builds.items()},
                   'platforms': []}
    monitor = CPUMonitor().start()
    status = 0
    try:
        for platform in args.platforms:
            run_platform(platform, builds[platform.key], urls, secrets, args, folder, environment['platforms'])
    except Refused as error:
        environment['refused'] = str(error)
        print(f'{RESULT_LINE} FAILED: {error}', file=sys.stderr, flush=True)
        status = 3
    finally:
        environment['cpu_during_run'] = monitor.stop()
        environment['finished'] = now_iso()
        (folder / 'environment.json').write_text(assert_shareable(json.dumps(environment, indent=2), secrets) + '\n')
    samples = read_samples(folder)
    write_csv(samples, folder / 'samples.csv')
    rows = summarize(samples, labels=('correctness',) if args.correctness else ('measure',))
    (folder / 'summary.json').write_text(json.dumps(rows, indent=2) + '\n')
    print(table(rows), flush=True)
    cpu = environment['cpu_during_run']
    print(f"{RESULT_LINE} {'finished' if status == 0 else 'FAILED'}: {len(samples)} samples in {folder}; "
          f"CPU peak {cpu.get('peak')} %, {cpu.get('seconds_over_budget')} s over the {CPU_BUDGET} % budget", flush=True)
    return status


def git_head():
    result = subprocess.run(['git', '-C', str(BENCHMARK), 'rev-parse', '--short', 'HEAD'], capture_output=True, text=True)
    clean = subprocess.run(['git', '-C', str(BENCHMARK), 'status', '--porcelain', '--', '.'], capture_output=True, text=True)
    return {'commit': result.stdout.strip() or None, 'clean': clean.returncode == 0 and clean.stdout.strip() == ''}


# MARK: - Report

def read_samples(folder):
    path = Path(folder) / 'samples.jsonl'
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def percentile(values, fraction):
    """Nearest rank: the smallest value with at least `fraction` of the values at or below it."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def stats(values):
    if not values:
        return None
    return {'n': len(values), 'p50': round(percentile(values, 0.5)), 'p90': round(percentile(values, 0.9)),
            'min': round(min(values)), 'max': round(max(values))}


def is_stall(sample):
    return sample['outcome'] == 'ok' and (sample.get('bufferingInHold', 0) > 0 or sample.get('errorInHold'))


def summarize(samples, labels=('measure',)):
    """Per platform, side, alias and action: attempts; failures (an error, or no motion within 20 s, or no result
    from the app); stalls (a buffering state, or an error, in the hold after first motion); first-motion and
    `.playing` times; memory."""
    groups = {}
    for sample in samples:
        if sample['label'] not in labels:
            continue
        key = (sample['platform'], sample['side'], sample['alias'], sample['action'])
        groups.setdefault(key, []).append(sample)
    rows = []
    order = {key: index for index, key in enumerate(SIDES)}
    for (platform, side, alias, action), group in sorted(
            groups.items(), key=lambda item: (item[0][0], STEPS.index(item[0][2:]), order[item[0][1]])):
        ok = [sample for sample in group if sample['outcome'] == 'ok']
        mib = 1048576
        rows.append({
            'platform': platform, 'side': side, 'label': SIDES[side].label, 'alias': alias, 'action': action,
            'attempts': len(group), 'failures': len(group) - len(ok),
            'errors': sum(sample['outcome'] == 'error' for sample in group),
            'timeouts': sum(sample['outcome'] == 'timeout' for sample in group),
            'no_result': sum(sample['outcome'] == 'no_result' for sample in group),
            'stalls': sum(is_stall(sample) for sample in group),
            'motion_ms': stats([sample['motionMs'] for sample in ok]),
            'clock_start_ms': stats([sample['clockStartMs'] for sample in ok if sample.get('clockStartMs') is not None]),
            'playing_ms': stats([sample['playingMs'] for sample in group if sample.get('playingMs') is not None]),
            'tick_interval_p50_ms': stats([sample['tickIntervalP50Ms'] for sample in ok if sample.get('tickIntervalP50Ms')]),
            'footprint_steady_mib': stats([sample['footprintSteadyBytes'] / mib for sample in ok if sample.get('footprintSteadyBytes')]),
            'footprint_peak_mib': stats([sample['footprintPeakBytes'] / mib for sample in group if sample.get('footprintPeakBytes')]),
        })
    return rows


def table(rows):
    lines = ['platform side     alias action    n fail  err  t/o stall   p50   p90   min   max  clk50 clk90  play50  mem50  peak']
    for row in rows:
        motion = row['motion_ms'] or {}
        playing = row['playing_ms'] or {}
        clock = row.get('clock_start_ms') or {}
        steady = row['footprint_steady_mib'] or {}
        peak = row['footprint_peak_mib'] or {}
        lines.append(
            f"{row['platform']:8} {row['label']:8} {row['alias']:5} {row['action']:8} {motion.get('n', 0):3} "
            f"{row['failures']:4} {row['errors']:4} {row['timeouts']:4} {row['stalls']:5} "
            f"{motion.get('p50', '-'):>5} {motion.get('p90', '-'):>5} {motion.get('min', '-'):>5} {motion.get('max', '-'):>5} "
            f"{clock.get('p50', '-'):>5} {clock.get('p90', '-'):>5} {playing.get('p50', '-'):>7} {steady.get('p50', '-'):>6} {peak.get('max', '-'):>5}")
    return '\n'.join(lines)


def comparison(rows, metric='motion_ms'):
    """4.0.0a18 against 3.7.4, per platform and step: the change in p50 and p90 of one number."""
    by_key = {(row['platform'], row['alias'], row['action'], row['side']): row for row in rows}
    lines = [f'{metric}: platform alias action   3.7.4 p50/p90   4.0.0a18 p50/p90   Δp50   Δp90']
    for (platform, alias, action, side), row in by_key.items():
        if side != '374' or (platform, alias, action, '400a18') not in by_key:
            continue
        old, new = row.get(metric), by_key[(platform, alias, action, '400a18')].get(metric)
        if not old or not new:
            continue
        lines.append(f"{platform:8} {alias:5} {action:8} {old['p50']:>6}/{old['p90']:<6}  {new['p50']:>8}/{new['p90']:<8} "
                     f"{new['p50'] - old['p50']:+6} {new['p90'] - old['p90']:+6}")
    return '\n'.join(lines)


def write_csv(samples, path):
    mib = 1048576
    with open(path, 'w', newline='') as file:
        writer = csv.DictWriter(file, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for sample in samples:
            def value(key, scale=None):
                number = sample.get(key)
                return round(number / scale, 1) if scale and isinstance(number, (int, float)) else number
            writer.writerow({
                'platform': sample.get('platform'), 'device': sample.get('device'), 'side': SIDES[sample['side']].label,
                'label': sample['label'], 'round': sample['round'], 'order': sample.get('order'), 'alias': sample['alias'],
                'action': sample['action'], 'outcome': sample['outcome'], 'motion_ms': value('motionMs'),
                'clock_start_ms': value('clockStartMs'), 'playing_ms': value('playingMs'), 'error_ms': value('errorMs'),
                'first_tick_ms': value('firstTickMs'), 'first_tick_media_ms': value('firstTickMediaMs'),
                'motion_media_ms': value('motionMediaMs'), 'buffering_in_hold': value('bufferingInHold'), 'error_in_hold': value('errorInHold'),
                'max_advance_gap_ms': value('maxAdvanceGapMs'), 'tick_interval_p50_ms': value('tickIntervalP50Ms'),
                'hold_ms': value('holdMs'), 'footprint_steady_mib': value('footprintSteadyBytes', mib),
                'footprint_peak_mib': value('footprintPeakBytes', mib), 'video_width': value('videoWidth'),
                'video_height': value('videoHeight'), 'states': sample.get('states'), 'vlcui_states': sample.get('vlcuiStates')})


def report(args):
    samples = []
    for folder in args.folders:
        samples += read_samples(folder)
    labels = tuple(args.labels.split(','))
    rows = summarize(samples, labels=labels)
    print(table(rows))
    print()
    print(comparison(rows))
    print()
    print(comparison(rows, 'clock_start_ms'))
    if args.csv:
        write_csv(samples, args.csv)
    if args.json:
        Path(args.json).write_text(json.dumps(rows, indent=2) + '\n')
    return 0


def sizes(args):
    lines = ['platform side      bundle MiB  zipped MiB  VLCKit binary MiB']
    values = {}
    for platform in args.platforms:
        for side in args.sides:
            path = build_record_path(side, platform, 'device')
            if not path.exists():
                raise Refused(f'No {side.label} {platform.key} device build: run `build --device` first')
            record = json.loads(path.read_text())
            framework = max(record['frameworks'].values(), key=lambda item: item['binary_bytes'] or 0, default={})
            values[(platform.key, side.key)] = (record['sizes']['bundle_bytes'], record['sizes']['zipped_bytes'],
                                                framework.get('binary_bytes') or 0)
            bundle, zipped, binary = values[(platform.key, side.key)]
            lines.append(f'{platform.key:8} {side.label:8} {bundle / 1048576:11.1f} {zipped / 1048576:11.1f} {binary / 1048576:18.1f}')
        old, new = values.get((platform.key, '374')), values.get((platform.key, '400a18'))
        if old and new:
            lines.append(f'{platform.key:8} {"Δ":8} {(new[0] - old[0]) / 1048576:+11.1f} {(new[1] - old[1]) / 1048576:+11.1f} '
                         f'{(new[2] - old[2]) / 1048576:+18.1f}')
    print('\n'.join(lines))
    return 0


# MARK: - Command line

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--wuwtv', default=os.environ.get('WUWTV_ROOT'),
                        help='the wuwtv task worktree (scripts/agent_build.sh, release_tests.py)')
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('build', 'run', 'sizes'):
        command = commands.add_parser(name)
        command.add_argument('--platform', default='ios,tvos')
        command.add_argument('--side', default=','.join(SIDE_ORDER))
    commands.choices['build'].add_argument('--device', action='store_true', help='Release device builds, for the app size')
    run_command = commands.choices['run']
    run_command.add_argument('--set', default='S1')
    run_command.add_argument('--rounds', type=int, default=20)
    run_command.add_argument('--warmup', type=int, default=1)
    run_command.add_argument('--correctness', action='store_true',
                             help='one round per side and platform, numbers thrown away; a busy Mac is allowed')
    run_command.add_argument('--start-by', type=parse_time, help='refuse to start after this UTC time')
    run_command.add_argument('--deadline', type=parse_time, help='launch no round that could end after this UTC time')
    run_command.add_argument('--allow-busy', action='store_true')
    report_command = commands.add_parser('report')
    report_command.add_argument('folders', nargs='+')
    report_command.add_argument('--csv')
    report_command.add_argument('--json')
    report_command.add_argument('--labels', default='measure')
    args = parser.parse_args(argv)
    try:
        if args.command in ('build', 'run', 'sizes'):
            args.platforms = [PLATFORMS[key] for key in args.platform.split(',')]
            args.sides = [SIDES[key] for key in args.side.split(',')]
        if args.command in ('build', 'run'):
            if not args.wuwtv:
                parser.error('--wuwtv <wuwtv task worktree> (or WUWTV_ROOT) is required')
            args.wuwtv = linked_worktree(args.wuwtv)
        if args.command == 'run':
            if args.rounds < 1 or args.warmup < 0 or len(args.sides) != 2:
                parser.error('--rounds must be positive, --warmup zero or more, and both sides run')
            if args.correctness:
                args.allow_busy, args.rounds, args.warmup = True, 1, 0
            args.load_profile = load_playlist_profile_function(args.wuwtv)
        return {'build': build, 'run': run, 'report': report, 'sizes': sizes}[args.command](args)
    except KeyError as error:
        parser.error(f'unknown platform or side: {error}')
    except Refused as error:
        print(f'{RESULT_LINE} FAILED: {error}', file=sys.stderr, flush=True)
        return 3


if __name__ == '__main__':
    sys.exit(main())
