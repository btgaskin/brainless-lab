"""Exercise report rejection paths against a disposable copy of a conformance run."""
import hashlib
from pathlib import Path
import re
import shutil
import sys
import tempfile
import tomllib
from report_freeze import load_record


def verify(source):
    load_record(source)
    for mode in ('settings','seed_stream','missing_inventory','protocol'):
        with tempfile.TemporaryDirectory() as temporary:
            parent=source.parent.parent
            run=Path(temporary)/'run'
            shutil.copytree(parent,run)
            record=run/source.relative_to(parent)
            if mode=='missing_inventory':
                p=record/'record.toml'
                text=p.read_text()
                text=re.sub(r'^"seeds\.csv" = "[a-f0-9]+"\n','',text,flags=re.M)
                p.write_text(text)
            elif mode=='protocol':
                p=next((run/'protocol/plans').glob('*.toml'))
                p.write_text(p.read_text().replace('tick = 1\n','tick = 2\n',1))
            else:
                name='resolved.toml' if mode=='settings' else 'seeds.csv'
                p=record/name
                old=hashlib.sha256(p.read_bytes()).hexdigest()
                text=p.read_text()
                if mode=='settings':
                    text=text.replace('input_weight = 1.875','input_weight = 2.0',1)
                else:
                    lines=text.splitlines()
                    extra=lines[1].split(',')
                    columns=lines[0].split(',')
                    extra[columns.index('stream')]='extra_node_state'
                    lines.append(','.join(extra))
                    text='\n'.join(lines)+'\n'
                p.write_text(text)
                assert hashlib.sha256(p.read_bytes()).hexdigest()!=old
                m=record/'record.toml'
                m.write_text(m.read_text().replace(old,hashlib.sha256(p.read_bytes()).hexdigest()))
            try:
                load_record(record)
            except ValueError:
                print('Rejected',mode)
            else:
                raise AssertionError('accepted '+mode)


if __name__=='__main__':
    verify(Path(sys.argv[1]))
