#!/usr/bin/env python3
"""Creates isolated native validation items; keeps an owner-only cleanup manifest."""
import importlib.util
import json
import pathlib
import uuid

spec = importlib.util.spec_from_file_location('reads', pathlib.Path(__file__).with_name('remaining-app-smoke.py'))
reads = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reads)
root = pathlib.Path.home() / 'Library/Application Support/ApplePersonalMCP/Validation'
root.mkdir(mode=0o700, exist_ok=True)
path = root / 'actions.json'
previous = json.loads(path.read_text()) if path.exists() else None
assert previous is None or previous.get('checks', {}).get('native_confirmed_cleanup'), 'Run actions-cleanup.py before creating another set of validation items'
previous = None
agent = previous['agent'] if previous else reads.admin('--agent-create', 'APM action validation', '--permissions', 'calendar.read,calendar.write,reminders.read,reminders.write,notes.read,notes.write')
manifest = previous or {'agent': agent, 'objects': [], 'checks': {}, 'tag': 'APM validation ' + str(uuid.uuid4())[:8]}

def save():
    path.write_text(json.dumps(manifest, indent=2))
    path.chmod(0o600)

def call(name, args=None, error=None):
    return reads.call(agent, name, args, error)

def remember(kind, row):
    manifest['objects'].append({'kind': kind, 'id': row['id']})
    save()
    return row

save()
tag = manifest['tag']
cal = next(x for x in call('calendar_list')['items'] if x['allows_modifications'])
event = next((x for x in manifest['objects'] if x['kind'] == 'calendar'), None) or remember('calendar', call('calendar_create', {'calendar_id': cal['id'], 'title': tag, 'date_from': '2026-11-10T00:00:00+08:00', 'date_to': '2026-11-11T00:00:00+08:00', 'time_zone': 'Asia/Shanghai', 'all_day': True}))
event = call('calendar_get', {'id': event['id']})
updated = call('calendar_update', {'id': event['id'], 'expected_modified': event['last_modified'], 'title': tag + ' updated'})
assert updated['title'] == tag + ' updated'
call('calendar_update', {'id': event['id'], 'expected_modified': '2000-01-01T00:00:00.000Z', 'title': 'must not apply'}, 'source_changed')
manifest['checks']['calendar_all_day_update_and_stale_rejection'] = True
series = remember('calendar_series', call('calendar_create', {'calendar_id': cal['id'], 'title': tag + ' DST', 'date_from': '2026-10-31T10:00:00-04:00', 'date_to': '2026-10-31T10:30:00-04:00', 'time_zone': 'America/New_York', 'recurrence': {'frequency': 'daily', 'count': 3}}))
rows = call('calendar_search', {'calendar_id': cal['id'], 'text': tag + ' DST', 'date_from': '2026-10-31T00:00:00Z', 'date_to': '2026-11-04T00:00:00Z'})['items']
assert [x['start'][11:13] for x in rows] == ['14', '15', '15']
middle = rows[1]
call('calendar_update', {'id': middle['id'], 'expected_modified': middle['last_modified'], 'occurrence_start': middle['occurrence_start'], 'scope': 'occurrence', 'title': tag + ' detached'})
remember('calendar_detached', call('calendar_search', {'calendar_id': cal['id'], 'text': tag + ' detached', 'date_from': '2026-10-31T00:00:00Z', 'date_to': '2026-11-04T00:00:00Z'})['items'][0])
manifest['checks']['recurrence_dst_and_single_occurrence_update'] = True
lst = next(x for x in call('reminders_list_lists')['items'] if x['allows_modifications'])
rem = remember('reminders', call('reminders_create', {'list_id': lst['id'], 'title': tag, 'due_components': {'year': 2026, 'month': 11, 'day': 10}, 'priority': 5}))
rem = call('reminders_get', {'id': rem['id']})
rem = call('reminders_update', {'id': rem['id'], 'expected_modified': rem['last_modified'], 'title': tag + ' updated'})
rem = call('reminders_get', {'id': rem['id']})
rem = call('reminders_complete', {'id': rem['id'], 'expected_modified': rem['last_modified'], 'completed': True})
assert rem['completed']
assert call('reminders_complete', {'id': rem['id'], 'expected_modified': 'stale but already completed', 'completed': True})['completed']
manifest['checks']['reminder_due_update_and_idempotent_completion'] = True
accounts = call('notes_list_accounts')['accounts']
folder = remember('notes_folder', call('notes_create_folder', {'account_id': accounts[0]['id'], 'name': tag}))
folder2 = remember('notes_folder', call('notes_create_folder', {'account_id': accounts[0]['id'], 'name': tag + ' destination'}))
note = remember('notes', call('notes_create', {'folder_id': folder['id'], 'title': tag, 'text': 'First line <literal> & 中文😀'}))
note = call('notes_get', {'id': note['id'], 'include_html': True})
note = call('notes_update', {'id': note['id'], 'expected_modified': note['last_modified'], 'expected_body_html': note['body']['text'], 'append_text': 'Second line'})
note = call('notes_get', {'id': note['id'], 'include_html': True})
note = call('notes_update', {'id': note['id'], 'expected_modified': note['last_modified'], 'expected_body_html': note['body']['text'], 'text': 'Replacement 中文😀'})
note = call('notes_get', {'id': note['id']})
assert 'Replacement 中文😀' in note['body']['text']
note = call('notes_move', {'id': note['id'], 'expected_modified': note['last_modified'], 'folder_id': folder2['id']})
manifest['objects'][-1]['id'] = note['id']
assert note['folder_id'] == folder2['id']
manifest['checks']['notes_plain_append_replace_move'] = True
save()
print(json.dumps({'checks': manifest['checks'], 'cleanup_manifest': str(path), 'created_objects': len(manifest['objects'])}, indent=2))
