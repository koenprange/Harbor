#!/usr/bin/env python3
"""Assemble a relocatable engine and notices; sources remain companion release artifacts."""
import importlib.util, json, pathlib, re, shutil, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('prepare_engine',ROOT/'scripts/prepare-engine.py')
prepare = importlib.util.module_from_spec(spec); spec.loader.exec_module(prepare)

def output(*args): return subprocess.check_output([str(x) for x in args],text=True,stderr=subprocess.STDOUT).strip()
def run(*args): subprocess.run([str(x) for x in args],check=True)
def dependencies(file):
    return re.findall(r'^\s+(.+?) \(compatibility version',output('/usr/bin/otool','-L',file),re.M)
def minimum(file):
    versions=re.findall(r'\bminos\s+(\d+(?:\.\d+)*)',output('/usr/bin/vtool','-show-build',file))
    if not versions: raise SystemExit('Cannot determine deployment target: '+str(file))
    return max(tuple(map(int,x.split('.'))) for x in versions)

def main():
    app = pathlib.Path(sys.argv[1]).resolve()
    trees=prepare.sources(); prepare.build(trees)
    prefix=pathlib.Path(output('brew','--prefix','transmission-cli')).resolve()
    source=prefix/'bin/transmission-daemon'
    expected=prepare.MANIFEST['transmission-cli']['version']
    if not re.match(r'(?:Transmission|transmission-daemon) '+re.escape(expected)+r'(?: |$)',output(source,'--version')):
        raise SystemExit('Installed daemon does not match the pinned source version')
    helpers=app/'Contents/Helpers'; frameworks=app/'Contents/Frameworks'
    notices=app/'Contents/Resources/ThirdParty'
    for directory in [helpers,frameworks,notices]: directory.mkdir(parents=True,exist_ok=True)
    daemon=helpers/'transmission-daemon'
    if daemon.exists(): daemon.chmod(0o755)
    shutil.copyfile(source,daemon); daemon.chmod(0o755)
    pending=[(source,daemon)]; seen={}; binaries=[]
    while pending:
        original,target=pending.pop(0)
        binaries.append(target)
        subprocess.run(['/usr/bin/codesign','--remove-signature',str(target)],capture_output=True)
        for dep in dependencies(original):
            if dep.startswith(('/usr/lib/','/System/Library/')): continue
            if pathlib.Path(dep).resolve()==original.resolve(): continue
            if not dep.startswith('/'):
                raise SystemExit('Unresolved non-system dependency: '+dep)
            filename=pathlib.Path(dep).name
            portable=prepare.PREFIX/'lib'/filename
            if not portable.exists(): raise SystemExit('Portable dependency missing: '+filename)
            if filename not in seen:
                dest=frameworks/filename
                if dest.exists(): dest.chmod(0o755)
                shutil.copyfile(portable.resolve(),dest); dest.chmod(0o755)
                seen[filename]=dest; pending.append((portable.resolve(),dest))
            replacement=('@executable_path/../Frameworks/' if target==daemon else '@loader_path/')+filename
            run('/usr/bin/install_name_tool','-change',dep,replacement,target)
        if target!=daemon: run('/usr/bin/install_name_tool','-id','@rpath/'+target.name,target)
    for binary in binaries:
        if minimum(binary) > (14,0):
            raise SystemExit('Bundled binary requires macOS newer than 14: '+binary.name)
        for dep in dependencies(binary):
            if dep.startswith('/') and not dep.startswith(('/usr/lib/','/System/Library/')):
                raise SystemExit('External runtime dependency remains: '+dep)
        if output('/usr/bin/lipo','-archs',binary)!='arm64':
            raise SystemExit('This packaging recipe currently supports arm64 only')
    for name,tree in trees.items():
        for file in tree.rglob('*'):
            if file.is_file() and re.match(r'^(copying|license|authors|notice|copyright)',file.name,re.I):
                destination=notices/name/file.relative_to(tree)
                destination.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(file,destination)
    shutil.copy2(ROOT/'Packaging/engine-manifest.json',notices/'manifest.json')
    shutil.copy2(ROOT/'Packaging/THIRD-PARTY.md',notices/'NOTICE.md')
    shutil.copy2(trees['libpsl']/'list/public_suffix_list.dat',notices/'libpsl/public_suffix_list.dat')
    recipes=prepare.SOURCES/'build-recipes';recipes.mkdir(exist_ok=True)
    (recipes/'scripts').mkdir(exist_ok=True)
    (recipes/'Packaging').mkdir(exist_ok=True)
    shutil.copy2(ROOT/'Packaging/engine-manifest.json',recipes/'Packaging/engine-manifest.json')
    shutil.copy2(prefix/'.brew/transmission-cli.rb',recipes/'transmission-cli.rb')
    shutil.copy2(ROOT/'scripts/prepare-engine.py',recipes/'scripts/prepare-engine.py')
    shutil.copy2(ROOT/'scripts/bundle-engine.py',recipes/'scripts/bundle-engine.py')
    (prepare.SOURCES/'README.txt').write_text('Corresponding upstream sources for the bundled engine and libraries.\nSHA-256 checksums and versions are in manifest.json. Build recipes are included.\nPublish this entire directory alongside the application archive or disk image.\nHarbor changes library load paths during packaging; engine source is unmodified.\n')
    (notices/'README.txt').write_text('Harbor uses Transmission as a separate process.\nComponent licenses and credits are included in this directory.\nCorresponding source archives and build recipes accompany the release download.\nSee manifest.json for versions and upstream locations.\n')
    print('Bundled engine and',len(seen),'portable libraries; matching sources:',prepare.SOURCES)

if __name__=='__main__': main()
