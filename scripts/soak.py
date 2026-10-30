#!/usr/bin/env python3
"""Prepare a bounded, isolated soak. `run --confirm-start` is a separate manual action."""
import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

GIB = 1024 ** 3
PROFILER_LOCK = Path.home() / 'Library/Application Support/Codex Test Coordination/instruments.lock'

class SafetyStop(RuntimeError):
    pass


def stamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def save(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.replace(path)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): value.update(chunk)
    return value.hexdigest()


def metainfo(data):
    """Small strict bencode reader; no extraction or payload download."""
    if not 0 < len(data) <= 4 * 1024 * 1024:
        raise ValueError('Torrent metadata size outside allowed range')
    pos = 0
    info_bytes = None
    def parse(depth=0):
        nonlocal pos, info_bytes
        if depth > 40 or pos >= len(data):
            raise ValueError('Invalid bencode nesting')
        token = data[pos:pos+1]
        if token.isdigit():
            colon = data.index(b':', pos)
            digits = data[pos:colon]
            if len(digits) > 9 or not digits.isdigit(): raise ValueError('Invalid string length')
            size = int(digits); pos = colon + 1
            if size > len(data) - pos: raise ValueError('Truncated string')
            result = data[pos:pos+size]; pos += size
            return result
        if token == b'i':
            end = data.index(b'e', pos); value = int(data[pos+1:end]); pos = end + 1
            return value
        if token in (b'd', b'l'):
            pos += 1; result = {} if token == b'd' else []
            while pos < len(data) and data[pos:pos+1] != b'e':
                if token == b'd':
                    key = parse(depth+1)
                    if not isinstance(key, bytes) or key in result: raise ValueError('Duplicate/invalid key')
                    start = pos; value = parse(depth+1); result[key] = value
                    if depth == 0 and key == b'info': info_bytes = data[start:pos]
                else: result.append(parse(depth+1))
            if pos >= len(data): raise ValueError('Unterminated container')
            pos += 1
            return result
        raise ValueError('Invalid bencode token')
    root = parse()
    if pos != len(data) or not isinstance(root, dict) or not isinstance(root.get(b'info'), dict):
        raise ValueError('Invalid torrent container')
    info = root[b'info']
    def component(raw):
        text = raw.decode('utf-8')
        if not text or text in ('.', '..') or any(c in text for c in ('/', '\\', '\0')):
            raise ValueError('Unsafe payload path')
        return text
    name = component(info[b'name'])
    if b'files' in info:
        files = info[b'files']
        if not isinstance(files, list) or not 1 <= len(files) <= 2000: raise ValueError('Invalid file count')
        paths = []
        for file in files:
            if not file[b'path'] or b'symlink path' in file or b'l' in file.get(b'attr', b''):
                raise ValueError('Empty or symbolic payload path')
            paths.append(tuple(component(part) for part in file[b'path']))
        if len(set(paths)) != len(paths): raise ValueError('Duplicate payload path')
        sizes = [file[b'length'] for file in files]
    else: sizes = [info[b'length']]
    if not all(type(size) is int and size >= 0 for size in sizes): raise ValueError('Invalid payload size')
    piece_length = info[b'piece length']; pieces = info[b'pieces']
    total = sum(sizes)
    if b'symlink path' in info or b'l' in info.get(b'attr', b''):
        raise ValueError('Symbolic payload path')
    if type(piece_length) is not int or piece_length <= 0 or not isinstance(pieces, bytes):
        raise ValueError('Invalid pieces')
    if len(pieces) != ((total + piece_length - 1) // piece_length) * 20:
        raise ValueError('Piece count does not match payload size')
    return {'name': name, 'bytes': total, 'file_count': len(sizes), 'hash': hashlib.sha1(info_bytes).hexdigest()}


def prepare(root, app, bundle, helper, torrents, coordination_id=None):
    root = root.resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any(p.name not in ('Engine.app', '.DS_Store') for p in root.iterdir()):
        raise ValueError('Choose a fresh dedicated run directory')
    root.chmod(0o700)
    if (root / 'plan.json').exists() or (root / 'state.json').exists(): raise ValueError('Run already prepared')
    entries = []
    for source in torrents:
        entry = metainfo(source.read_bytes()); entry['source'] = str(source.resolve()); entries.append(entry)
    if not entries or len(entries) > 4 or not 0 < sum(e['bytes'] for e in entries) <= 8 * GIB:
        raise ValueError('Choose 1–4 torrents totaling at most 8 GiB')
    if len({e['name'] for e in entries}) != len(entries) or len({e['hash'] for e in entries}) != len(entries):
        raise ValueError('Duplicate payload names or torrents')
    engine = app.resolve() / 'Contents/Helpers/transmission-daemon'
    executable = bundle.resolve() / 'Contents/MacOS/HarborPackageTests'
    if not engine.is_file() or not executable.is_file() or not helper.is_file():
        raise ValueError('Build the standalone engine and test bundle before preparing')
    # Pin the complete engine/framework bundle and the test bundle; no services are launched.
    pinned_app = root / 'Engine.app'
    if app.resolve() != pinned_app: shutil.copytree(app, pinned_app)
    pinned_bundle = root / 'HarborSoak.xctest'; shutil.copytree(bundle, pinned_bundle)
    (root / 'torrents').mkdir()
    for index, entry in enumerate(entries):
        target = root / 'torrents' / (str(index) + '.torrent')
        shutil.copyfile(entry.pop('source'), target)
        entry['metainfo'] = str(target); entry['sha256'] = digest(target)
    files = [p for p in pinned_app.rglob('*') if p.is_file()] + [p for p in pinned_bundle.rglob('*') if p.is_file()]
    pinned_runner = root / 'soak.py'
    shutil.copyfile(Path(__file__), pinned_runner)
    files.append(pinned_runner)
    hashes = {str(p.relative_to(root)): digest(p) for p in files}
    plan = {'schema': 1, 'status': 'prepared-not-started', 'prepared_at': stamp(),
            'coordination_id': coordination_id or ('harbor-soak-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')), 'root': str(root), 'hours': 48,
            'sample_seconds': 30, 'watchdog_seconds': 10, 'ui_cycle_seconds': 300,
            'payload_limit': 8 * GIB, 'min_free_bytes': 100 * GIB,
            'download_kBps': 1000, 'upload_kBps': 64,
            'download_budget': 12 * GIB, 'upload_budget': 4 * GIB,
            'rss_limit': 3 * GIB, 'report_limit': 32 * 1024 ** 2,
            'helper': str(helper.resolve()), 'helper_sha256': digest(helper),
            'engine': str(pinned_app / 'Contents/Helpers/transmission-daemon'),
            'test_binary': str(pinned_bundle / 'Contents/MacOS/HarborPackageTests'),
            'profiler_lock': str(PROFILER_LOCK), 'automatic_instruments': False,
            'torrents': entries, 'pinned_sha256': hashes}
    save(root / 'plan.json', plan)
    return plan


def load(root):
    root = root.resolve(); plan = json.loads((root / 'plan.json').read_text())
    if plan['schema'] != 1 or Path(plan['root']) != root or plan['status'] != 'prepared-not-started':
        raise ValueError('Not a prepared soak root')
    return root, plan


def verify(plan, root):
    root = root.resolve()
    if (plan['hours'] != 48 or sum(t['bytes'] for t in plan['torrents']) > 8 * GIB
        or plan['min_free_bytes'] < 100 * GIB or not 1 <= plan['download_kBps'] <= 1000
        or not 1 <= plan['upload_kBps'] <= 64 or not 1 <= plan['rss_limit'] <= 3 * GIB
        or not 1 <= plan['download_budget'] <= 12 * GIB or not 1 <= plan['upload_budget'] <= 4 * GIB
        or not 1 <= plan['watchdog_seconds'] <= 10 or plan['report_limit'] > 32 * 1024 ** 2):
        raise ValueError('Invalid duration/payload budget')
    for relative, expected in plan['pinned_sha256'].items():
        path = (root / relative).resolve()
        if not path.is_relative_to(root) or digest(path) != expected: raise ValueError('Pinned build changed')
    if digest(Path(plan['helper'])) != plan['helper_sha256']: raise ValueError('Xcode helper changed; prepare again')
    for entry in plan['torrents']:
        path = Path(entry['metainfo']).resolve()
        if not path.is_relative_to(root) or digest(path) != entry['sha256']:
            raise ValueError('Torrent metadata changed')
        actual = metainfo(path.read_bytes())
        if any(actual[k] != entry[k] for k in actual): raise ValueError('Torrent manifest changed')
    if shutil.disk_usage(root).free < plan['min_free_bytes'] + sum(t['bytes'] for t in plan['torrents']):
        raise SafetyStop('Insufficient free disk reserve')


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); return sock.getsockname()[1]


class RPC:
    def __init__(self, port, password):
        self.url = f'http://127.0.0.1:{port}/transmission/rpc'
        self.auth = 'Basic ' + base64.b64encode(('harbor-soak:' + password).encode()).decode()
        self.token = None
        # No proxy or redirects for an authenticated loopback request.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args): return None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    def call(self, method, params=None):
        for _ in range(2):
            headers = {'Authorization': self.auth, 'Content-Type': 'application/json'}
            if self.token: headers['X-Transmission-Session-Id'] = self.token
            request = urllib.request.Request(self.url, data=json.dumps({'jsonrpc': '2.0', 'id': 1,
                'method': method, 'params': params or {}}).encode(), headers=headers)
            try:
                with self.opener.open(request, timeout=2) as response: value = json.load(response)
                if 'error' in value: raise RuntimeError('Test daemon rejected RPC request')
                return value['result']
            except urllib.error.HTTPError as error:
                if error.code != 409: raise RuntimeError('Test daemon RPC HTTP error') from None
                self.token = error.headers['X-Transmission-Session-Id']
        raise RuntimeError('Test daemon session negotiation failed')


def bounded_pipe(pipe, path):
    """Keep at most three 8-MiB log segments, regardless of child output volume."""
    limit = 8 * 1024 ** 2
    with pipe:
        stream = path.open('ab')
        try:
            while True:
                chunk = pipe.read(8192)
                if not chunk: break
                if stream.tell() + len(chunk) > limit:
                    stream.close()
                    for n in (2, 1):
                        source = path.with_suffix('.log.' + str(n-1)) if n > 1 else path
                        target = path.with_suffix('.log.' + str(n))
                        if source.exists(): source.replace(target)
                    stream = path.open('wb')
                stream.write(chunk); stream.flush()
        finally: stream.close()


def sample(pids):
    text = subprocess.check_output(['/bin/ps', '-p', ','.join(map(str, pids)), '-o', 'pid=,rss=,pcpu='],
                                   text=True, env={**os.environ, 'LC_ALL': 'C'})
    return [{'pid': int(a), 'rss_bytes': int(b) * 1024, 'cpu_percent': float(c)}
            for a, b, c in (line.split() for line in text.splitlines())]


def budget_reason(plan, free, rss, downloaded, uploaded):
    if free < plan['min_free_bytes']: return 'disk-reserve'
    if rss > plan['rss_limit']: return 'rss-limit'
    if downloaded >= plan['download_budget'] or uploaded >= plan['upload_budget']: return 'network-budget'
    return None


def run(root, confirmed):
    if not confirmed: raise ValueError('Explicit --confirm-start required; preparation never starts a run')
    root, plan = load(root)
    with (root / '.run.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if (root / 'state.json').exists(): raise ValueError('This prepared run was already used')
        if (root / 'stop-requested.json').exists(): raise ValueError('Prepared run was cancelled')
        verify(plan, root)
        _run(root, plan)


def _run(root, plan):
    children = []; threads = []; interrupted = []; rpc = None
    profile = root / 'profile'; profile.mkdir(mode=0o700)
    downloads = root / 'Downloads'; downloads.mkdir()
    logs = root / 'logs'; logs.mkdir()
    state = {'status': 'starting', 'coordination_id': plan['coordination_id'], 'started_at': stamp()}
    save(root / 'state.json', state)
    previous = {sig: signal.signal(sig, lambda *_: interrupted.append('signal')) for sig in (signal.SIGINT, signal.SIGTERM)}
    def launch(args, label, env=None, stdin=False):
        child = subprocess.Popen(args, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        children.append(child)
        thread = threading.Thread(target=bounded_pipe, args=(child.stdout, logs / (label + '.log')), daemon=True)
        thread.start(); threads.append(thread)
        return child
    try:
        port = free_port(); password = secrets.token_urlsafe(32); salt = secrets.token_hex(16)
        verifier = '{' + hashlib.sha1((password + salt).encode()).hexdigest() + salt
        settings = {'rpc-enabled': True, 'rpc-bind-address': '127.0.0.1', 'rpc-port': port,
            'rpc-authentication-required': True, 'rpc-username': 'harbor-soak', 'rpc-password': verifier,
            'rpc-whitelist-enabled': True, 'rpc-whitelist': '127.0.0.1',
            'download-dir': str(downloads), 'incomplete-dir-enabled': False, 'preallocation': 0,
            'peer-port': free_port(), 'peer-port-random-on-start': False, 'port-forwarding-enabled': False,
            'speed-limit-down-enabled': True, 'speed-limit-down': plan['download_kBps'],
            'speed-limit-up-enabled': True, 'speed-limit-up': plan['upload_kBps'],
            'download-queue-enabled': True, 'download-queue-size': 1,
            'peer-limit-global': 80, 'peer-limit-per-torrent': 40,
            'dht-enabled': True, 'pex-enabled': True, 'lpd-enabled': False,
            'ratio-limit-enabled': True, 'ratio-limit': 1.0, 'watch-dir-enabled': False,
            'start-added-torrents': False, 'umask': '077',
            'script-torrent-added-enabled': False, 'script-torrent-done-enabled': False}
        save(profile / 'settings.json', settings); (profile / 'settings.json').chmod(0o600)
        engine = launch([plan['engine'], '--foreground', '--config-dir', str(profile), '--log-level', 'warn'], 'engine')
        rpc = RPC(port, password)
        ready = time.monotonic() + 20
        while True:
            if interrupted or (root / 'stop-requested.json').exists(): raise SafetyStop('cancelled-before-ready')
            if engine.poll() is not None: raise RuntimeError('Test engine exited during startup')
            try: rpc.call('session_get', {'fields': ['version']}); break
            except (OSError, RuntimeError):
                if time.monotonic() > ready: raise RuntimeError('Test engine not ready') from None
                time.sleep(.25)
        hashes = []
        for entry in plan['torrents']:
            result = rpc.call('torrent_add', {'metainfo': base64.b64encode(Path(entry['metainfo']).read_bytes()).decode(),
                'paused': True, 'download_dir': str(downloads)})
            actual = result.get('torrent_added') or result.get('torrent_duplicate')
            if not actual or actual['hash_string'].lower() != entry['hash']: raise SafetyStop('Torrent hash mismatch')
            hashes.append(entry['hash'])
        env = {k: v for k, v in os.environ.items() if not k.startswith('HARBOR_')}
        env.update(HARBOR_SOAK_EXERCISE='1', DYLD_LIBRARY_PATH='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib',
            DYLD_FRAMEWORK_PATH='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks')
        worker = launch([plan['helper'], '--test-bundle-path', plan['test_binary'], '--testing-library', 'swift-testing',
                         '--filter', 'LiveSoakTests'], 'harbor-ui', env, stdin=True)
        # Ephemeral credentials travel only over the child's private stdin pipe.
        worker.stdin.write(json.dumps({'port': port, 'username': 'harbor-soak', 'password': password,
            'root': str(root), 'hours': plan['hours'], 'interval': plan['ui_cycle_seconds']}).encode())
        worker.stdin.close()
        ui_ready = time.monotonic() + 30
        while not (root / 'ui-report.json').exists():
            if worker.poll() is not None: raise RuntimeError('UI helper exited before readiness')
            if interrupted or (root / 'stop-requested.json').exists(): raise SafetyStop('cancelled-before-ui-ready')
            if time.monotonic() > ui_ready: raise RuntimeError('UI helper did not become ready')
            time.sleep(.25)
        if json.loads((root / 'ui-report.json').read_text()).get('connected') is not True:
            raise RuntimeError('UI helper is not connected')
        rpc.call('torrent_start', {'ids': hashes})
        state.update(status='running', engine_pid=engine.pid, ui_pid=worker.pid, rpc_port=port,
                     payload_bytes=sum(t['bytes'] for t in plan['torrents']))
        save(root / 'state.json', state)
        deadline = time.monotonic() + plan['hours'] * 3600; next_sample = 0; frozen = False
        while time.monotonic() < deadline:
            if interrupted or (root / 'stop-requested.json').exists(): state['status'] = 'cancelled'; break
            if any(child.poll() is not None for child in children): raise RuntimeError('Owned soak process exited early')
            observed = rpc.call('torrent_get', {'fields': ['hash_string', 'total_size', 'honors_session_limits']})['torrents']
            if {t['hash_string'].lower() for t in observed} != set(hashes):
                raise SafetyStop('unexpected-transfer-set')
            if sum(t['total_size'] for t in observed) > plan['payload_limit']:
                raise SafetyStop('payload-limit')
            limits = {'speed_limit_down_enabled': True, 'speed_limit_down': plan['download_kBps'],
                'speed_limit_up_enabled': True, 'speed_limit_up': plan['upload_kBps']}
            effective = rpc.call('session_get', {'fields': list(limits)})
            if any(effective.get(key) != value for key, value in limits.items()):
                rpc.call('session_set', limits)
            if any(not t['honors_session_limits'] for t in observed):
                rpc.call('torrent_set', {'ids': hashes, 'honors_session_limits': True})
            stats = rpc.call('session_stats')['cumulative_stats']
            processes = sample([os.getpid(), engine.pid, worker.pid])
            free = shutil.disk_usage(root).free
            reason = budget_reason(plan, free, sum(p['rss_bytes'] for p in processes),
                                   stats['downloaded_bytes'], stats['uploaded_bytes'])
            if reason == 'network-budget':
                rpc.call('torrent_stop')
                if not frozen:
                    frozen = True
                    state['network_paused_at'] = stamp(); save(root / 'state.json', state)
            elif reason and reason != 'network-budget': raise SafetyStop(reason)
            if time.monotonic() >= next_sample:
                metrics = root / 'samples.jsonl'
                if metrics.exists() and metrics.stat().st_size > plan['report_limit']: raise SafetyStop('report-limit')
                row = {'at': stamp(), 'free_bytes': free, 'processes': processes,
                       'downloaded_bytes': stats['downloaded_bytes'], 'uploaded_bytes': stats['uploaded_bytes'], 'network_paused': frozen}
                with metrics.open('a') as stream: stream.write(json.dumps(row) + '\n')
                next_sample = time.monotonic() + plan['sample_seconds']
            time.sleep(min(plan['watchdog_seconds'], max(0, deadline-time.monotonic())))
        else: state['status'] = 'completed'
    except SafetyStop as error:
        state.update(status='safety-stopped', reason=str(error))
    except Exception as error:
        # No exceptions with request bodies/headers or credential-bearing representations in logs.
        state.update(status='failed', error_type=type(error).__name__)
    finally:
        save(root / 'stop-requested.json', {'at': stamp()})
        if rpc:
            try: rpc.call('torrent_stop')
            except Exception: pass
        # Let the UI test release views/tasks and finish its own report before SIGTERM.
        if len(children) > 1:
            try: children[1].wait(timeout=20)
            except subprocess.TimeoutExpired: pass
        for child in reversed(children):
            if child.poll() is None: child.terminate()
            try: child.wait(timeout=30)
            except subprocess.TimeoutExpired: child.kill(); child.wait(); state['forced_cleanup'] = True
        for thread in threads: thread.join(timeout=2)
        state['exit_codes'] = [child.returncode for child in children]
        if state.get('status') == 'completed' and (state['exit_codes'] != [0, 0] or state.get('forced_cleanup')):
            state['status'] = 'failed-cleanup'
        state['finished_at'] = stamp(); save(root / 'state.json', state)
        for sig, handler in previous.items(): signal.signal(sig, handler)
    if state['status'] not in ('completed', 'cancelled'): raise RuntimeError('Soak stopped; inspect private state.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    p = sub.add_parser('prepare'); p.add_argument('--root', type=Path, required=True)
    p.add_argument('--engine-app', type=Path, required=True); p.add_argument('--test-bundle', type=Path, required=True)
    p.add_argument('--coordination-id'); p.add_argument('--helper', type=Path, required=True); p.add_argument('--torrent', type=Path, action='append', required=True)
    for action in ('run', 'status', 'stop', 'verify'):
        p = sub.add_parser(action); p.add_argument('--root', type=Path, required=True)
        if action == 'run': p.add_argument('--confirm-start', action='store_true')
    p = sub.add_parser('profile'); p.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == 'prepare':
        plan = prepare(args.root, args.engine_app, args.test_bundle, args.helper, args.torrent, args.coordination_id)
        print(json.dumps({k: plan[k] for k in ('status', 'root', 'hours', 'torrents')}, indent=2))
    elif args.action == 'run': run(args.root, args.confirm_start)
    elif args.action == 'status':
        root, plan = load(args.root)
        print((root/'state.json').read_text() if (root/'state.json').exists() else json.dumps({'status': plan['status']}))
    elif args.action == 'stop':
        root, _ = load(args.root); save(root / 'stop-requested.json', {'at': stamp()})
    elif args.action == 'verify':
        root, plan = load(args.root); verify(plan, root); print('Prepared artifacts and budgets verified; nothing started')
    elif args.action == 'profile':
        if not args.command: raise ValueError('Provide an explicit profiler command')
        PROFILER_LOCK.parent.mkdir(parents=True, exist_ok=True)
        with PROFILER_LOCK.open('a+') as lock:
            os.chmod(PROFILER_LOCK, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            raise SystemExit(subprocess.call(args.command))

if __name__ == '__main__':
    main()
