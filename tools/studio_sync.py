"""Deploy editable sources through the already connected Roblox Studio MCP session.
The session socket is local-only and requires an explicit studio id. No cloud publish.
"""
import argparse
import json
import pathlib
import socket


def call(tool, arguments):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(120)
        connection.connect('/tmp/hookman-studio-mcp.sock')
        connection.sendall((json.dumps({'tool': tool, 'arguments': arguments}, ensure_ascii=False) + '\n').encode())
        result = json.loads(connection.makefile().readline())
        if result.get('is_error') or result.get('error'):
            raise RuntimeError(result)
        return result


def source_map():
    result = {}
    for path in pathlib.Path('src').rglob('*.luau'):
        name = path.relative_to('src').as_posix()
        kind = 'ModuleScript'
        for suffix, class_name in (('.server.luau', 'Script'), ('.client.luau', 'LocalScript'), ('.luau', 'ModuleScript')):
            if name.endswith(suffix):
                name, kind = name[:-len(suffix)], class_name
                break
        result[name] = (kind, path.read_text())
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--studio', required=True)
    parser.add_argument('--baseline', required=True, help='JSON map of last observed/applied script sources')
    args = parser.parse_args()
    checkpoint = pathlib.Path(args.baseline)
    baseline = json.loads(checkpoint.read_text())
    count = 0
    for path, (kind, source) in sorted(source_map().items()):
        previous = baseline.get(path)
        if previous == source:
            continue
        call('multi_edit', {'studio_id': args.studio, 'datamodel_type': 'Edit',
            'file_path': 'game.' + path.replace('/', '.'), 'className': kind if previous is None else '',
            'edits': [{'old_string': previous or '', 'new_string': source}]})
        baseline[path] = source
        checkpoint.write_text(json.dumps(baseline, ensure_ascii=False))
        count += 1
        print('Updated', path, flush=True)
    print('Deployed', count, 'scripts; original backup and cloud publication unchanged')
