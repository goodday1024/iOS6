#!/usr/bin/env python3
import argparse, io, sys, zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT))
from services.api.package_security import validate, PackageError
p=argparse.ArgumentParser(description='Retro6 .simapp packaging CLI')
p.add_argument('command',choices=['pack','validate']);p.add_argument('source');p.add_argument('-o','--output');args=p.parse_args()
try:
    if args.command=='pack':
        root=Path(args.source).resolve();buffer=io.BytesIO()
        with zipfile.ZipFile(buffer,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
            for path in sorted(root.rglob('*')):
                if path.is_symlink():raise PackageError('禁止符号链接')
                if path.is_file():z.write(path,path.relative_to(root).as_posix())
        data=buffer.getvalue();manifest,sha=validate(data);output=Path(args.output or manifest['name'].replace(' ','-')+'.simapp');output.write_bytes(data);print(f'{output}: {manifest["id"]}@{manifest["version"]}, SHA256={sha}')
    else:
        m,sha=validate(Path(args.source).read_bytes());print(f'VALID {m["id"]}@{m["version"]} SHA256={sha}')
except (PackageError,OSError) as e:sys.exit(str(e))
