#!/usr/bin/env python3
"""Developer-only build tooling. Downloads pinned upstream sources and builds portable dylibs."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, tarfile, tempfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT/'Packaging/engine-manifest.json').read_text())
SOURCES = ROOT/'dist/engine-sources'
# Some upstream libtool install rules cannot handle spaces in their prefix.
WORK = pathlib.Path(tempfile.gettempdir()) / ('harbor-engine-'+hashlib.sha256((str(ROOT)+json.dumps(MANIFEST,sort_keys=True)).encode()).hexdigest()[:12])
PREFIX = WORK/'prefix'

def run(args, cwd=None, env=None):
    subprocess.run([str(x) for x in args], cwd=cwd, env=env, check=True)

def sources():
    SOURCES.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT/'Packaging/engine-manifest.json', SOURCES/'manifest.json')
    result = {}
    for name, entry in MANIFEST.items():
        filename = entry['url'].rsplit('/',1)[-1]
        archive = SOURCES/filename
        if not archive.exists():
            temp = archive.with_suffix(archive.suffix+'.partial')
            run(['/usr/bin/curl','--fail','--location','--retry','2','--output',temp,entry['url']])
            temp.replace(archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != entry['sha256']:
            raise SystemExit('Source checksum mismatch: '+name)
        destination = WORK/name
        if not destination.exists():
            destination.mkdir()
            with tarfile.open(archive) as tar:
                for member in tar.getmembers():
                    path = (destination/member.name).resolve()
                    if not path.is_relative_to(destination.resolve()):
                        raise SystemExit('Unsafe source archive path')
                    if member.issym() or member.islnk():
                        target = ((path.parent if member.issym() else destination)/member.linkname).resolve()
                        if not target.is_relative_to(destination.resolve()):
                            raise SystemExit('Unsafe source archive link')
                tar.extractall(destination)
        directories = [p for p in destination.iterdir() if p.is_dir()]
        if len(directories) != 1: raise SystemExit('Unexpected source tree: '+name)
        result[name] = directories[0]
    return result

def build(trees):
    PREFIX.mkdir(parents=True,exist_ok=True)
    env = os.environ.copy()
    env.update(MACOSX_DEPLOYMENT_TARGET='14.0', CFLAGS='-O2 -fPIC -mmacosx-version-min=14.0',
               LDFLAGS='-L'+str(PREFIX/'lib')+' -mmacosx-version-min=14.0', CPPFLAGS='-I'+str(PREFIX/'include'))
    jobs = str(min(8,os.cpu_count() or 2))
    for name, args in [('libiconv',['--disable-nls']), ('libevent',['--disable-openssl','--disable-samples','--disable-libevent-regress']),
                       ('libpsl',['--enable-builtin','--enable-runtime=libicucore','--disable-static','--with-libiconv-prefix='+str(PREFIX)])]:
        marker = PREFIX/(name+'.built')
        if marker.exists(): continue
        run([trees[name]/'configure','--prefix='+str(PREFIX),*args],cwd=trees[name],env=env)
        run(['make','-j'+jobs],cwd=trees[name],env=env)
        run(['make','install'],cwd=trees[name],env=env)
        marker.touch()
    marker = PREFIX/'miniupnpc.built'
    if not marker.exists():
        run(['make','-j'+jobs,'CFLAGS='+env['CFLAGS'],'LDFLAGS='+env['LDFLAGS']],cwd=trees['miniupnpc'],env=env)
        run(['make','install','INSTALLPREFIX='+str(PREFIX)],cwd=trees['miniupnpc'],env=env)
        marker.touch()
    print('Portable libraries:', PREFIX)

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--sources-only',action='store_true')
    args=parser.parse_args()
    trees=sources()
    if not args.sources_only: build(trees)
