#!/usr/bin/env python3
"""Snapshot the running GUI session. After Harbor quits, migrate without payload changes.
Password is requested on the terminal and only a Transmission-compatible salted hash is saved.
"""
import base64, datetime, getpass, hashlib, json, os, pathlib, secrets, shutil, socket, sys, urllib.request, urllib.error
root = pathlib.Path.home() / 'Library/Application Support/Harbor'
source = pathlib.Path.home() / 'Library/Application Support/Transmission'
preferences = pathlib.Path.home() / 'Library/Preferences/org.m0k.transmission.plist'
mode = sys.argv[1]
if mode == 'snapshot':
    if (root/'Transmission/settings.json').exists():
        raise SystemExit('Migration already exists; refusing to overwrite it.')
    user = input('Local RPC username: ')
    password = getpass.getpass('Local RPC password: ')
    token = None
    def rpc(method, params):
        global token
        for _ in range(2):
            req = urllib.request.Request('http://127.0.0.1:9091/transmission/rpc', data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),headers={'Authorization':'Basic '+base64.b64encode((user+':'+password).encode()).decode(),'Content-Type':'application/json',**({'X-Transmission-Session-Id':token} if token else {})})
            try:
                with urllib.request.urlopen(req,timeout=8) as r: result=json.load(r)
                if 'error' in result: raise RuntimeError('RPC failed')
                return result['result']
            except urllib.error.HTTPError as e:
                if e.code != 409: raise RuntimeError('Local RPC authentication/connection failed') from None
                token=e.headers['X-Transmission-Session-Id']
        raise RuntimeError('Session negotiation failed')
    settings=rpc('session_get',{})
    torrents=rpc('torrent_get',{'fields':['hash_string','name','status','percent_done','download_dir','queue_position']})['torrents']
    # Only daemon settings supported by session_get; no scripts/watchers are enabled.
    keys='alt_speed_down alt_speed_enabled alt_speed_time_begin alt_speed_time_day alt_speed_time_enabled alt_speed_time_end alt_speed_up blocklist_enabled blocklist_url dht_enabled download_dir download_queue_enabled download_queue_size encryption incomplete_dir incomplete_dir_enabled lpd_enabled peer_limit_global peer_limit_per_torrent peer_port peer_port_random_on_start pex_enabled port_forwarding_enabled queue_stalled_enabled queue_stalled_minutes rename_partial_files idle_seeding_limit idle_seeding_limit_enabled seed_queue_enabled seed_queue_size seed_ratio_limit seed_ratio_limited speed_limit_down speed_limit_down_enabled speed_limit_up speed_limit_up_enabled start_added_torrents utp_enabled'.split()
    settings={k:settings[k] for k in keys if k in settings}
    salt=secrets.token_hex(8)
    settings.update({'rpc_enabled':True,'rpc_bind_address':'127.0.0.1','rpc_port':9091,'rpc_authentication_required':True,'rpc_username':user,'rpc_password':'{'+hashlib.sha1((password+salt).encode()).hexdigest()+salt,'rpc_whitelist_enabled':True,'rpc_whitelist':'127.0.0.1','rpc_host_whitelist_enabled':True,'rpc_host_whitelist':'localhost','watch_dir_enabled':False,'script_torrent_added_enabled':False,'script_torrent_done_enabled':False,'script_torrent_done_seeding_enabled':False})
    del password
    os.umask(0o077)
    root.mkdir(parents=True,exist_ok=True,mode=0o700)
    pending=root/'migration-pending';pending.mkdir(mode=0o700)
    legacy = {k.replace('_','-'):v for k,v in settings.items()}
    # Transmission 4.x keeps legacy config names for the ratio fields.
    for old,new in [('seed-ratio-limit','ratio-limit'),('seed-ratio-limited','ratio-limit-enabled')]:
        if old in legacy: legacy[new] = legacy.pop(old)
    (pending/'settings.json').write_text(json.dumps(legacy,indent=2))
    (pending/'transfers.json').write_text(json.dumps(torrents,indent=2))
    print('Snapshot saved:',len(torrents),'current transfers. Peer port:',settings.get('peer_port'))
elif mode == 'finish':
    # Do not copy live resume state or overwrite an existing migration.
    with socket.socket() as s:
        if s.connect_ex(('127.0.0.1',9091)) == 0: raise SystemExit('RPC still running. Quit Harbor/Transmission before finishing.')
    pending=root/'migration-pending'
    if not (pending/'settings.json').exists(): raise SystemExit('No snapshot available.')
    destination=root/'Transmission'
    if destination.exists(): raise SystemExit('Destination exists; refusing to overwrite.')
    backup=root/('GUI-backup-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(mode=0o700)
    if source.exists(): shutil.copytree(source,backup/'Transmission')
    if preferences.exists(): shutil.copy2(preferences,backup/preferences.name)
    destination.mkdir(mode=0o700)
    for old,new in [('Torrents','torrents'),('Resume','resume'),('blocklists','blocklists')]:
        if (source/old).exists(): shutil.copytree(source/old,destination/new)
    shutil.copy2(pending/'settings.json',destination/'settings.json')
    shutil.copy2(pending/'transfers.json',backup/'transfers-at-migration.json')
    for p in destination.rglob('*'): p.chmod(0o700 if p.is_dir() else 0o600)
    shutil.rmtree(pending)
    print('Migration complete. Backup:',backup)
else: raise SystemExit('Usage: migrate-transmission.py snapshot|finish')
