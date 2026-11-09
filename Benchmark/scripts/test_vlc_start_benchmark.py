#!/usr/bin/env python3
"""Tests for vlc_start_benchmark.py: python3 -m unittest Benchmark/scripts/test_vlc_start_benchmark.py"""
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vlc_start_benchmark as bench  # noqa: E402

A, B = bench.SIDES['374'], bench.SIDES['400a18']
IOS, TVOS = bench.PLATFORMS['ios'], bench.PLATFORMS['tvos']
PROFILE = {'playlistURL': 'http://example.invalid:8080/get.php?username=user%2Bname&password=p4ss&type=m3u_plus&output=ts'}
STREAM_SET = {'L1': {'stream_id': 11}, 'L2': {'stream_id': 12}, 'L3': {'stream_id': 13},
              'M1': {'stream_id': 21, 'container': 'mkv'}, 'E1': {'episode_id': '31', 'container': 'mkv'}}


def sample(side='374', label='measure', outcome='ok', motion=1000.0, alias='L1', action='start', **extra):
    return {'event': 'sample', 'platform': 'ios', 'device': 'S-IPHONE', 'side': side, 'label': label, 'round': 1,
            'alias': alias, 'action': action, 'outcome': outcome, 'motionMs': motion if outcome == 'ok' else None,
            'playingMs': 900.0, 'bufferingInHold': 0, 'errorInHold': False, 'footprintSteadyBytes': 100 * 1048576,
            'footprintPeakBytes': 120 * 1048576, 'states': 'opening>playing', **extra}


class FakeSimulators:
    """`xcrun simctl` with a device list; records every call."""

    def __init__(self, devices):
        self.devices = devices
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append(command)
        arguments = command[2:]
        if arguments[:2] == ['list', 'devices']:
            listing = {}
            for device in self.devices:
                listing.setdefault(device['runtime'], []).append({k: v for k, v in device.items() if k != 'runtime'})
            return subprocess.CompletedProcess(command, 0, json.dumps({'devices': listing}), '')
        if arguments[0] == 'create':
            self.devices.append({'name': arguments[1], 'udid': 'NEW', 'deviceTypeIdentifier': arguments[2],
                                 'runtime': arguments[3], 'state': 'Shutdown', 'isAvailable': True})
            return subprocess.CompletedProcess(command, 0, 'NEW\n', '')
        if arguments[0] == 'delete':
            self.devices = [device for device in self.devices if device['udid'] != arguments[1]]
        if arguments[0] == 'get_app_container':
            return subprocess.CompletedProcess(command, 2, '', 'not installed')
        return subprocess.CompletedProcess(command, 0, '', '')

    def mutations(self):
        return [call[2:4] for call in self.calls if call[2] in ('uninstall', 'terminate', 'delete', 'shutdown', 'create',
                                                                  'install', 'boot', 'erase')]


def device(name, udid, runtime='com.apple.CoreSimulator.SimRuntime.iOS-27-0',
           kind='com.apple.CoreSimulator.SimDeviceType.iPhone-17', state='Shutdown'):
    return {'name': name, 'udid': udid, 'runtime': runtime, 'deviceTypeIdentifier': kind, 'state': state, 'isAvailable': True}


class StreamTests(unittest.TestCase):

    def test_addresses_follow_the_apps_xtream_rule(self):
        urls = bench.stream_urls(STREAM_SET, PROFILE)
        self.assertEqual(urls['L1'], 'http://example.invalid:8080/live/user%2Bname/p4ss/11.ts')
        self.assertEqual(urls['L2'], 'http://example.invalid:8080/live/user%2Bname/p4ss/12.ts')
        self.assertEqual(urls['M1'], 'http://example.invalid:8080/movie/user%2Bname/p4ss/21.mkv')
        self.assertEqual(urls['E1'], 'http://example.invalid:8080/series/user%2Bname/p4ss/31.mkv')

    def test_a_path_prefix_before_get_php_is_kept(self):
        profile = {'playlistURL': 'https://example.invalid/panel/get.php?username=u&password=p'}
        self.assertEqual(bench.stream_urls(STREAM_SET, profile)['L1'], 'https://example.invalid/panel/live/u/p/11.ts')

    def test_standalone_dots_are_encoded_like_networkkit(self):
        self.assertEqual(bench.encode_segment('..'), '%2E%2E')
        self.assertEqual(bench.encode_segment('a b/c'), 'a%20b%2Fc')

    def test_a_profile_without_account_is_refused(self):
        with self.assertRaises(bench.Refused):
            bench.stream_urls(STREAM_SET, {'playlistURL': 'http://example.invalid/list.m3u'})

    def test_plan_holds_the_round_and_both_timings(self):
        urls = bench.stream_urls(STREAM_SET, PROFILE)
        plan = bench.plan(B, 'measure', 3, urls)
        self.assertEqual([(s['alias'], s['action']) for s in plan['steps']],
                         [('L1', 'start'), ('L2', 'next'), ('L1', 'previous'), ('M1', 'start'), ('E1', 'start')])
        self.assertEqual((plan['side'], plan['round'], plan['failAfterSeconds'], plan['holdSeconds']), ('400a18', 3, 20, 5))


class PrivacyTests(unittest.TestCase):

    def test_records_with_an_address_or_credential_are_refused(self):
        urls = bench.stream_urls(STREAM_SET, PROFILE)
        secrets = bench.secrets_of(PROFILE, urls)
        for text in ('{"x": "http://elsewhere.invalid/a"}', '{"x": "p4ss"}', '{"x": "example.invalid:8080"}',
                     '{"x": "user%2Bname"}', '{"x": "user+name"}'):
            with self.subTest(text=text), self.assertRaises(bench.Refused):
                bench.assert_shareable(text, secrets)
        line = json.dumps(sample())
        self.assertEqual(bench.assert_shareable(line, secrets), line)

    def test_plan_files_are_owner_only(self):
        with tempfile.TemporaryDirectory() as folder:
            path = bench.write_private(Path(folder) / 'plan.json', '{}')
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_the_printed_line_has_aliases_and_numbers_only(self):
        line = bench.sample_line(IOS, sample(motion=1234.4))
        self.assertIn('L1 start', line)
        self.assertIn('1234 ms', line)
        self.assertNotIn('http', line)

    def test_private_inputs_must_be_0600_and_outside_the_repository(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'streams.json'
            path.write_text('{}')
            path.chmod(0o644)
            with self.assertRaises(bench.Refused):
                bench.private_file(path)
            path.chmod(0o600)
            self.assertEqual(bench.private_file(path), path.resolve())


class ScheduleTests(unittest.TestCase):

    def test_warmups_first_then_a_b_b_a(self):
        entries = bench.schedule(rounds=4, warmup=1)
        self.assertEqual(entries[:2], [('warmup', 1, '374'), ('warmup', 1, '400a18')])
        self.assertEqual([side for _, _, side in entries[2:]],
                         ['374', '400a18', '400a18', '374', '374', '400a18', '400a18', '374'])

    def test_each_side_gets_its_rounds_numbered(self):
        entries = [entry for entry in bench.schedule(rounds=20, warmup=1) if entry[0] == 'measure']
        for side in ('374', '400a18'):
            self.assertEqual([number for _, number, s in entries if s == side], list(range(1, 21)))

    def test_correctness_is_one_round_per_side(self):
        self.assertEqual(bench.schedule(20, 1, correctness=True), [('correctness', 1, '374'), ('correctness', 1, '400a18')])


class PinTests(unittest.TestCase):

    def test_the_copy_pins_vlcui_and_vlckit_spm_for_its_side(self):
        with tempfile.TemporaryDirectory() as folder:
            project = bench.prepare_copy(A, folder)
            text = (project / 'project.pbxproj').read_text()
            self.assertIn(f'revision = {A.vlcui};', text)
            self.assertNotIn(B.vlcui, text)
            self.assertEqual(text.count('WUW_BENCHMARK_SUFFIX = 374;'), 2)
            pins = bench.resolved_pins(bench.resolved_file(project))
            self.assertEqual(pins, {'vlcui': A.vlcui, 'vlckit-spm': A.vlckit_spm})
            self.assertTrue((Path(folder) / 'App/BenchmarkRunner.swift').exists())
        # The committed project is untouched.
        self.assertIn('WUW_BENCHMARK_SUFFIX = 400a18;', (bench.PROJECT / 'project.pbxproj').read_text())

    def test_a_floating_vlckit_spm_is_refused(self):
        with self.assertRaises(bench.Refused):
            bench.verify_pins({'vlcui': A.vlcui, 'vlckit-spm': 'f' * 40}, A)
        with self.assertRaises(bench.Refused):
            bench.verify_pins({'vlcui': A.vlcui}, A)
        with self.assertRaises(bench.Refused):
            bench.verify_pins({'vlcui': B.vlcui, 'vlckit-spm': B.vlckit_spm}, A)
        self.assertTrue(bench.verify_pins({'vlcui': B.vlcui, 'vlckit-spm': B.vlckit_spm}, B))

    def test_the_sides_have_their_own_product_and_bundle(self):
        self.assertNotEqual(A.product, B.product)
        self.assertNotEqual(A.bundle_id, B.bundle_id)

    def test_each_app_is_kept_outside_derived_data(self):
        with tempfile.TemporaryDirectory() as folder:
            built = Path(folder) / 'DerivedData/VLCStartBenchmark374.app'
            built.mkdir(parents=True)
            (built / 'VLCStartBenchmark374').write_text('binary')
            with mock.patch.object(bench, 'BUILDS', Path(folder) / 'builds'):
                kept = bench.keep_app(built, A, IOS, 'simulator')
            # Xcode later removes the built app as a stale output of the other side's build.
            (built / 'VLCStartBenchmark374').unlink()
            self.assertEqual((kept / 'VLCStartBenchmark374').read_text(), 'binary')
            self.assertEqual(kept.parent.name, '374-ios-simulator')

    def test_sizes_thin_a_fat_framework_to_arm64(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'Bench.app'
            framework = app / 'Frameworks/Engine.framework'
            framework.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(bench.plistlib.dumps({'CFBundleExecutable': 'Bench'}))
            (app / 'Bench').write_text('x')
            (framework / 'Info.plist').write_bytes(bench.plistlib.dumps({'CFBundleExecutable': 'Engine'}))
            source = Path(folder) / 'engine.c'
            source.write_text('int engine(void) { return 1; }\n')
            built = subprocess.run(['xcrun', 'clang', '-dynamiclib', '-arch', 'arm64', '-arch', 'x86_64', str(source),
                                    '-o', str(framework / 'Engine')], capture_output=True)
            if built.returncode:
                self.skipTest('no clang for a fat test binary')
            sizes = bench.app_sizes(app)
        self.assertLess(sizes['thinned']['framework_binary_bytes'], sizes['framework_binary_bytes'])
        self.assertLess(sizes['thinned']['bundle_bytes'], sizes['bundle_bytes'])

    def test_build_never_touches_a_simulator_and_refuses_inside_the_lock(self):
        with mock.patch.dict(os.environ, {'WUWTV_AGENT_BUILD_LOCK_HELD': '1'}):
            with self.assertRaises(bench.Refused):
                bench.build(mock.Mock(platforms=[IOS], sides=[A], wuwtv=Path('/nonexistent'), device=False))
        calls = []

        def fake_call(command, **kwargs):
            calls.append(command)
            return 1  # the build fails: nothing after it may run
        with mock.patch.dict(os.environ, {'WUWTV_AGENT_BUILD_LOCK_HELD': ''}), \
                mock.patch.object(bench.subprocess, 'call', side_effect=fake_call), \
                mock.patch.object(bench.subprocess, 'check_output', return_value='/tmp/WUWTV-agent-wt-x\n'), \
                mock.patch.object(bench, 'derived_data_name', return_value='WUWTV-agent-wt-x'), \
                mock.patch.object(bench, 'simctl', side_effect=AssertionError('simctl during build')):
            with self.assertRaises(bench.Refused):
                bench.build(mock.Mock(platforms=[IOS], sides=[A], wuwtv=Path('/w'), device=False))
        command = calls[0]
        self.assertIn('generic/platform=iOS Simulator', command)
        self.assertIn('-onlyUsePackageVersionsFromResolvedFile', command)
        self.assertEqual(command[0], '/w/scripts/agent_build.sh')


class LibraryTests(unittest.TestCase):

    def report(self, side, version, changeset=None):
        return {'libvlcVersion': version, 'libvlcChangeset': changeset, 'vlckitVersion': '1.0', 'bundleID': side.bundle_id}

    def test_the_expected_engine_passes(self):
        self.assertTrue(bench.check_library(A, self.report(A, '3.0.24 Vetinari', A.libvlc_changeset)))
        self.assertTrue(bench.check_library(B, self.report(B, '4.0.0-dev Otto Chriek', B.libvlc_changeset)))

    def test_another_engine_is_refused(self):
        cases = (
            (A, self.report(A, '4.0.0-dev', A.libvlc_changeset)),        # the other generation
            (B, self.report(B, '3.0.24 Vetinari', B.libvlc_changeset)),
            (A, self.report(A, '3.0.21 Vetinari', A.libvlc_changeset)),  # an older 3.x
            (A, self.report(A, '3.0.24 Vetinari', '3.0.24-0-g0000000')),  # another 3.0.24 build
            (B, self.report(B, '4.0.0-dev Otto Chriek', 'other-4.0-build')),  # another alpha
            (A, {'libvlcVersion': None, 'libvlcChangeset': None, 'bundleID': A.bundle_id}),  # no library at all
            (A, self.report(B, '3.0.24 Vetinari', A.libvlc_changeset)),  # the other side's app answered
        )
        for side, report in cases:
            with self.subTest(side=side.key, report=report), self.assertRaises(bench.Refused):
                bench.check_library(side, report)


class SimulatorGuardTests(unittest.TestCase):

    def setUp(self):
        self.release = device('WUWTV Release iPhone', 'REL')
        self.tv = device('WUWTV Release Apple TV', 'RELTV', runtime='com.apple.CoreSimulator.SimRuntime.tvOS-27-0',
                         kind='com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K')
        self.fake = FakeSimulators([self.release, self.tv])

    def test_removal_refuses_every_device_but_the_benchmarks(self):
        with mock.patch.object(bench.subprocess, 'run', side_effect=self.fake):
            for udid in ('REL', 'RELTV', 'UNKNOWN'):
                with self.subTest(udid=udid):
                    with self.assertRaises(bench.Refused):
                        bench.remove_app(udid, A.bundle_id)
                    with self.assertRaises(bench.Refused):
                        bench.delete_device(udid)
        self.assertEqual(self.fake.mutations(), [])

    def test_only_benchmark_apps_are_removed(self):
        self.fake.devices.append(device('WUWTV Benchmark VLC iPhone', 'BENCH', state='Booted'))
        with mock.patch.object(bench.subprocess, 'run', side_effect=self.fake):
            with self.assertRaises(bench.Refused):
                bench.remove_app('BENCH', 'com.wuwtv.dev')
            self.assertTrue(bench.remove_app('BENCH', B.bundle_id))
        self.assertIn(['uninstall', 'BENCH'], self.fake.mutations())

    def test_the_device_copies_the_release_devices_type_and_runtime(self):
        with mock.patch.object(bench.subprocess, 'run', side_effect=self.fake):
            created = bench.create_device(TVOS)
        create = next(call for call in self.fake.calls if call[2] == 'create')
        self.assertEqual(create[3:], ['WUWTV Benchmark VLC Apple TV', self.tv['deviceTypeIdentifier'], self.tv['runtime']])
        self.assertEqual(created['name'], 'WUWTV Benchmark VLC Apple TV')

    def test_leftovers_are_removed_and_release_devices_kept(self):
        self.fake.devices += [device('WUWTV Benchmark VLC iPhone', 'OLD', state='Booted')]
        with mock.patch.object(bench.subprocess, 'run', side_effect=self.fake), mock.patch.object(bench.time, 'sleep'):
            self.assertEqual(bench.remove_leftovers(IOS), ['OLD'])
        names = {entry['name'] for entry in self.fake.devices}
        self.assertEqual(names, {'WUWTV Release iPhone', 'WUWTV Release Apple TV'})
        self.assertTrue(all(call[3] == 'OLD' for call in self.fake.calls if call[2] in ('uninstall', 'delete', 'shutdown')))


class RunGuardTests(unittest.TestCase):

    def test_run_refuses_outside_the_lock(self):
        with mock.patch.dict(os.environ, {'WUWTV_AGENT_BUILD_LOCK_HELD': ''}):
            with self.assertRaises(bench.Refused):
                bench.run(mock.Mock())

    def test_sigterm_becomes_systemexit_so_cleanup_runs(self):
        previous = signal.getsignal(signal.SIGTERM)
        cleaned = []
        try:
            signal.signal(signal.SIGTERM, bench.terminate_as_exit)
            with self.assertRaises(SystemExit):
                try:
                    os.kill(os.getpid(), signal.SIGTERM)
                    signal.pause()  # never reached: the handler raises first
                finally:
                    cleaned.append(True)
            # A second TERM during the cleanup is ignored, so the cleanup can finish.
            self.assertEqual(signal.getsignal(signal.SIGTERM), signal.SIG_IGN)
        finally:
            signal.signal(signal.SIGTERM, previous)
        self.assertEqual(cleaned, [True])

    def test_a_busy_mac_is_checked_again_and_recorded(self):
        readings = iter([{'samples': [40.0], 'mean': 40.0}, {'samples': [12.0], 'mean': 12.0}])
        with mock.patch.object(bench.time, 'sleep'):
            records = bench.wait_for_idle(attempts=6, check=lambda: next(readings))
        self.assertEqual([record['mean'] for record in records], [40.0, 12.0])

    def test_the_cpu_record_is_this_runs_own(self):
        monitor = bench.CPUMonitor(interval=15)
        self.assertEqual(monitor.summary()['peak'], None)
        monitor.samples = [(0, 50.0), (15, 80.0), (30, 75.0), (45, 40.0)]
        summary = monitor.summary()
        self.assertEqual((summary['peak'], summary['seconds_over_budget'], summary['samples']), (80.0, 30, 4))

    def test_other_queue_holders_are_found_and_our_own_lock_is_not(self):
        with tempfile.TemporaryDirectory() as folder:
            for name, pid in (('simulators.lock', os.getpid()), ('build-1.lock', os.getpid()), ('build-2.lock', os.getppid())):
                (Path(folder) / name).mkdir()
                (Path(folder) / name / 'pid').write_text(str(pid))
            holders = bench.queue_holders(folder, own={os.getpid()})
        self.assertEqual(holders, [{'lock': 'build-2.lock', 'pid': os.getppid()}])

    def test_load_playlist_profile_is_imported_from_the_worktree(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'scripts').mkdir()
            (Path(folder) / 'scripts/release_tests.py').write_text(
                'from __future__ import annotations\nfrom dataclasses import dataclass\n\n@dataclass\nclass Row:\n'
                '    name: str\n\ndef load_playlist_profile(path):\n    return {"from": "worktree"}\n')
            function = bench.load_playlist_profile_function(Path(folder))
        self.assertEqual(function('x'), {'from': 'worktree'})

    def test_the_real_release_tests_module_imports(self):
        wuwtv = os.environ.get('WUWTV_ROOT')
        if not wuwtv:
            self.skipTest('WUWTV_ROOT is not set')
        self.assertTrue(callable(bench.load_playlist_profile_function(Path(wuwtv))))

    def test_wuwtv_must_be_a_task_worktree(self):
        with tempfile.TemporaryDirectory() as folder:
            subprocess.run(['git', 'init', '-q', folder], check=True)
            with self.assertRaises(bench.Refused):
                bench.linked_worktree(folder)


class RoundTests(unittest.TestCase):
    """One launch, with a fake app writing its results into the data container."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.container = Path(self.folder.name)
        self.urls = bench.stream_urls(STREAM_SET, PROFILE)
        self.secrets = bench.secrets_of(PROFILE, self.urls)
        self.plan_at_launch = None
        self.emitted = []

    def tearDown(self):
        self.folder.cleanup()

    def run_round(self, side, lines, pid=None):
        def fake_simctl(*arguments, check=True):
            if arguments[0] == 'get_app_container':
                return subprocess.CompletedProcess(arguments, 0, f'{self.container}\n', '')
            if arguments[0] == 'launch':
                plan_path = self.container / 'Documents/plan.json'
                self.plan_at_launch = (stat.S_IMODE(plan_path.stat().st_mode), json.loads(plan_path.read_text()))
                (self.container / 'Documents/results.jsonl').write_text(''.join(json.dumps(line) + '\n' for line in lines))
                return subprocess.CompletedProcess(arguments, 0, f'{side.bundle_id}: {pid or 999999}\n', '')
            return subprocess.CompletedProcess(arguments, 0, '', '')
        with mock.patch.object(bench, 'simctl', side_effect=fake_simctl), mock.patch.object(bench.time, 'sleep'):
            return bench.launch_round({'udid': 'BENCH'}, side, 'measure', 1, self.urls, self.secrets, self.emitted.append,
                                      timeout=5)

    def library(self, side, changeset=None):
        return {'event': 'library', 'side': side.key, 'bundleID': side.bundle_id, 'libvlcVersion': side.libvlc_prefix + ' x',
                'libvlcChangeset': changeset or side.libvlc_changeset}

    def test_a_full_round(self):
        lines = [self.library(B)] + [sample(side='400a18', alias=a, action=b) for a, b in bench.STEPS] + [{'event': 'done'}]
        library, samples = self.run_round(B, lines, pid=os.getpid())
        self.assertEqual(library['libvlcChangeset'], B.libvlc_changeset)
        self.assertEqual([s['outcome'] for s in samples], ['ok'] * 5)
        mode, plan = self.plan_at_launch
        self.assertEqual(mode, 0o600)
        self.assertEqual(plan['steps'][0]['url'], self.urls['L1'])
        self.assertFalse((self.container / 'Documents/plan.json').exists())
        self.assertFalse((self.container / 'Documents/results.jsonl').exists())

    def test_another_engine_stops_the_run_and_the_plan_is_removed(self):
        with self.assertRaises(bench.Refused):
            self.run_round(A, [self.library(A, changeset='3.0.21-0-gabc'), sample()])
        self.assertFalse((self.container / 'Documents/plan.json').exists())
        self.assertEqual(self.emitted, [])

    def test_an_app_that_exits_leaves_no_result_for_the_rest(self):
        lines = [self.library(A), sample(alias='L1', action='start'), sample(alias='L2', action='next')]
        _, samples = self.run_round(A, lines)  # pid 999999 is not alive
        self.assertEqual([s['outcome'] for s in samples], ['ok', 'ok', 'no_result', 'no_result', 'no_result'])
        self.assertEqual([(s['alias'], s['action']) for s in samples[2:]], list(bench.STEPS[2:]))

    def test_a_result_with_an_address_is_refused(self):
        with self.assertRaises(bench.Refused):
            self.run_round(A, [self.library(A), sample(states=self.urls['M1'])])


class SummaryTests(unittest.TestCase):

    def test_warmups_and_correctness_are_never_measured(self):
        rows = bench.summarize([sample(label='warmup', motion=99999), sample(label='correctness'), sample(motion=1000)])
        self.assertEqual(rows[0]['motion_ms']['n'], 1)
        self.assertEqual(rows[0]['motion_ms']['max'], 1000)

    def test_failures_stalls_and_percentiles(self):
        samples = [sample(motion=value) for value in range(100, 2100, 100)]
        samples += [sample(outcome='timeout'), sample(outcome='error'), sample(outcome='no_result'),
                    sample(motion=500, bufferingInHold=2), sample(motion=600, errorInHold=True)]
        row = bench.summarize(samples)[0]
        self.assertEqual((row['attempts'], row['failures'], row['errors'], row['timeouts'], row['no_result']), (25, 3, 1, 1, 1))
        self.assertEqual(row['stalls'], 2)
        self.assertEqual(row['motion_ms']['n'], 22)
        self.assertEqual((row['motion_ms']['p50'], row['motion_ms']['min'], row['motion_ms']['max']), (900, 100, 2000))
        self.assertEqual(row['footprint_steady_mib']['p50'], 100)

    def test_rows_follow_the_round_and_compare_the_sides(self):
        samples = [sample(side=side, alias=alias, action=action, motion=motion)
                   for side, motion in (('374', 1000), ('400a18', 1500))
                   for alias, action in bench.STEPS]
        rows = bench.summarize(samples)
        self.assertEqual([(r['alias'], r['action'], r['side']) for r in rows][:4],
                         [('L1', 'start', '374'), ('L1', 'start', '400a18'), ('L2', 'next', '374'), ('L2', 'next', '400a18')])
        self.assertIn('+500', bench.comparison(rows))

    def test_clock_start_is_summarized_and_compared_apart_from_first_motion(self):
        samples = [sample(side='374', motion=1200, clockStartMs=900.0),
                   sample(side='400a18', motion=2400, clockStartMs=700.0),
                   sample(side='400a18', motion=2500)]  # no plausible clock start: left out, not zero
        rows = bench.summarize(samples)
        self.assertEqual(rows[1]['clock_start_ms']['n'], 1)
        self.assertIn('+1200', bench.comparison(rows))
        self.assertIn('-200', bench.comparison(rows, 'clock_start_ms'))

    def test_csv_has_one_row_per_attempt(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'samples.csv'
            bench.write_csv([sample(), sample(outcome='timeout')], path)
            lines = path.read_text().splitlines()
        self.assertEqual(lines[0].split(',')[:4], ['platform', 'device', 'side', 'label'])
        self.assertEqual(len(lines), 3)
        self.assertIn('3.7.4', lines[1])


if __name__ == '__main__':
    unittest.main()
