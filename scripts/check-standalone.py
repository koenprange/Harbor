#!/usr/bin/env python3
"""Readiness/shutdown smoke test in a disposable profile; no payload downloads."""
import base64, hashlib, json, os, pathlib, secrets, socket, subprocess, sys, tempfile, time, urllib.request, urllib.error
app=pathlib.Path(sys.argv[1]).resolve()
helper=app/'Contents/Helpers/transmission-daemon'
assert helper.is_file(), 'Bundled engine missing'
files=[helper,*list((app/'Contents/Frameworks').glob('*.dylib'))]
for file in files:
    deps=subprocess.check_output(['/usr/bin/otool','-L',str(file)],text=True)
    assert '/opt/homebrew/' not in deps and '/usr/local/' not in deps, 'External library dependency'

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0));return s.getsockname()[1]

with tempfile.TemporaryDirectory(prefix='harbor-install-check-') as temp:
    root=pathlib.Path(temp);folder=root/'Downloads';folder.mkdir()
    port=free_port();password=secrets.token_urlsafe(32);salt=secrets.token_hex(8)
    settings={'rpc-enabled':True,'rpc-bind-address':'127.0.0.1','rpc-port':port,
        'rpc-authentication-required':True,'rpc-username':'install-check',
        'rpc-password':'{'+hashlib.sha1((password+salt).encode()).hexdigest()+salt,
        'rpc-whitelist-enabled':True,'rpc-whitelist':'127.0.0.1',
        'download-dir':str(folder),'peer-port':free_port(),'bind-address-ipv4':'127.0.0.1',
        'bind-address-ipv6':'::1','dht-enabled':False,'pex-enabled':False,
        'port-forwarding-enabled':False,'watch-dir-enabled':False}
    config=root/'settings.json';config.write_text(json.dumps(settings));config.chmod(0o600)
    with open(root/'engine.log','w') as log:
        child=subprocess.Popen([str(helper),'--foreground','--config-dir',str(root),'--log-level','warn'],
            env={'HOME':temp,'PATH':'/usr/bin:/bin','TMPDIR':temp},stdout=log,stderr=log)
        try:
            token=None;last=None
            for _ in range(80):
                assert child.poll() is None, 'Bundled engine exited during startup'
                req=urllib.request.Request(f'http://127.0.0.1:{port}/transmission/rpc',
                    data=json.dumps({'jsonrpc':'2.0','id':1,'method':'session_get',
                        'params':{'fields':['version','download_dir']}}).encode(),
                    headers={'Authorization':'Basic '+base64.b64encode(('install-check:'+password).encode()).decode(),
                        'Content-Type':'application/json',**({'X-Transmission-Session-Id':token} if token else {})})
                try:
                    with urllib.request.urlopen(req,timeout=.5) as response: result=json.load(response)
                    assert result['result']['download_dir']==str(folder)
                    print('Bundled engine ready with no Homebrew on PATH:',result['result']['version'])
                    break
                except urllib.error.HTTPError as e:
                    if e.code==409:token=e.headers['X-Transmission-Session-Id']
                    else:raise
                except (urllib.error.URLError,TimeoutError) as e:last=e
                time.sleep(.1)
            else:raise RuntimeError('Engine not ready: '+str(last))
            child.terminate();child.wait(timeout=30)
            assert child.returncode==0, 'Engine failed graceful shutdown'
            print('Graceful shutdown and saved configuration verified; no torrents added')
        finally:
            if child.poll() is None:child.terminate()
            try:child.wait(timeout=30)
            except subprocess.TimeoutExpired:child.kill();child.wait()
