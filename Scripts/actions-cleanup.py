#!/usr/bin/env python3
"""Clean up only recorded validation IDs, with the App's normal human prompts."""
import importlib.util
import json
import pathlib
import subprocess

spec = importlib.util.spec_from_file_location('reads', pathlib.Path(__file__).with_name('remaining-app-smoke.py'))
reads = importlib.util.module_from_spec(spec); spec.loader.exec_module(reads)
path = pathlib.Path.home() / 'Library/Application Support/ApplePersonalMCP/Validation/actions.json'
manifest = json.loads(path.read_text()); agent = manifest['agent']
def call(name, args):
    p = subprocess.run([reads.BRIDGE, '--credential-file', agent['credential_file'], 'call', name, json.dumps(args)], capture_output=True, text=True, timeout=600)
    value = json.loads(p.stdout)
    assert not value['isError'], name + ': ' + value['body'].get('error', {}).get('code', '')
    return value['body']
objects = sorted(manifest['objects'], key=lambda x: {'calendar_detached': 0, 'calendar_series': 1, 'calendar': 2, 'reminders': 3, 'notes': 4, 'notes_folder': 5}[x['kind']])
for item in objects:
    if item.get('deleted'): continue
    kind, id = item['kind'], item['id']
    if kind.startswith('calendar'):
        if kind == 'calendar_series':
            rows = call('calendar_search', {'date_from': '2026-10-30T00:00:00Z', 'date_to': '2026-11-05T00:00:00Z', 'text': manifest['tag']})['items']
            row = next(x for x in rows if x['id'] == id)
            args = {'id': id, 'occurrence_start': row['occurrence_start'], 'scope': 'future', 'expected_modified': row['last_modified']}
        else:
            row = call('calendar_get', {'id': id})
            args = {'id': id, 'expected_modified': row['last_modified']}
            if row['recurring']: args.update(occurrence_start=row['occurrence_start'], scope='occurrence')
        assert row['title'].startswith('APM validation')
        result = call('calendar_delete', args)
    elif kind == 'reminders':
        row = call('reminders_get', {'id': id}); assert row['title'].startswith('APM validation')
        result = call('reminders_delete', {'id': id, 'expected_modified': row['last_modified']})
    elif kind == 'notes':
        row = call('notes_get', {'id': id}); assert row['title'].startswith('APM validation')
        result = call('notes_delete', {'id': id, 'expected_modified': row['last_modified']})
    else:
        row = next(x for x in call('notes_list_folders', {})['folders'] if x['id'] == id)
        assert row['name'].startswith('APM validation')
        result = call('notes_delete_folder', {'folder_id': id, 'expected_name': row['name']})
    if result['status'] != 'deleted':
        print(json.dumps({'cleanup': 'cancelled', 'remaining': sum(not x.get('deleted', False) for x in objects)})); break
    item['deleted'] = True
    path.write_text(json.dumps(manifest, indent=2)); path.chmod(0o600)
else:
    reads.admin('--agent-revoke', agent['agent']['id'])
    manifest['checks']['native_confirmed_cleanup'] = True
    path.write_text(json.dumps(manifest, indent=2))
    print(json.dumps({'cleanup': 'complete', 'objects': len(objects)}))
