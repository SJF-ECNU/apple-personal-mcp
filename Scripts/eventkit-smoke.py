#!/usr/bin/env python3
"""Validate actual EventKit reads using temporary, independently scoped Agents. No writes."""
import datetime
import json
import subprocess
import uuid

HOST = '/Applications/ApplePersonalMCP.app/Contents/MacOS/ApplePersonalMCPHost'
BRIDGE = '/Applications/ApplePersonalMCP.app/Contents/Helpers/apple-personal-mcp'


def admin(*args):
    p = subprocess.run([HOST, *args], capture_output=True, text=True, timeout=15)
    assert p.returncode == 0, 'Native administration failed'
    return json.loads(p.stdout)


def call(agent, tool, args=None, expected_error=None):
    p = subprocess.run([BRIDGE, '--credential-file', agent['credential_file'], 'call', tool, json.dumps(args or {})],
                       capture_output=True, text=True, timeout=30)
    result = json.loads(p.stdout)
    if expected_error:
        assert result['isError'] and result['body']['error']['code'] == expected_error
    else:
        assert not result['isError'], tool + ': ' + result['body'].get('error', {}).get('code', '')
    return result['body']


def notes_roundtrip(agent, tool, item):
    args = {'id': item['id']}
    if tool == 'calendar_get':
        args['occurrence_start'] = item['occurrence_start']
    initial = call(agent, tool, args)['notes']
    text = ''
    offset = 0
    while True:
        page = call(agent, tool, {**args, 'body_offset': offset, 'max_chars': 31})['notes']
        assert page['offset'] == offset and page['total_scalars'] == initial['total_scalars']
        text += page['text']
        if page['next_offset'] is None:
            break
        offset = page['next_offset']
        assert offset <= 100000, 'Unexpectedly large notes; inspect separately'
    assert len(text) == initial['total_scalars']
    assert text.startswith(initial['text'])
    return True


def main():
    agents = []
    report = {}
    try:
        for app in ['calendar', 'reminders']:
            agents.append(admin('--agent-create', 'APM EventKit validation ' + str(uuid.uuid4()), '--permissions', app + '.read'))
        calendar, reminders = agents
        state = call(calendar, 'system_status')['applications']['calendar']['state']
        assert state == 'ready', 'Calendar system permission is not ready'
        assert call(reminders, 'system_status')['applications']['reminders']['state'] == 'ready'
        report['calendar_count'] = len(call(calendar, 'calendar_list')['items'])
        report['reminder_list_count'] = len(call(reminders, 'reminders_list_lists')['items'])
        now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
        events = call(calendar, 'calendar_search', {'date_from': (now - datetime.timedelta(days=180)).isoformat(timespec='seconds'), 'date_to': (now + datetime.timedelta(days=180)).isoformat(timespec='seconds'), 'limit': 2})
        report['event_instances_in_360_days'] = events['total']
        report['event_notes_roundtrip'] = notes_roundtrip(calendar, 'calendar_get', events['items'][0]) if events['items'] else 'no_local_events'
        rows = call(reminders, 'reminders_search', {'limit': 2})
        report['reminders_total'] = rows['total']
        report['reminder_notes_roundtrip'] = notes_roundtrip(reminders, 'reminders_get', rows['items'][0]) if rows['items'] else 'no_local_reminders'
        call(calendar, 'reminders_list_lists', expected_error='permission_denied')
        call(reminders, 'calendar_list', expected_error='permission_denied')
        report['cross_application_permissions_enforced'] = True
        call(calendar, 'calendar_search', {'date_from': '2026-01-01', 'date_to': '2028-01-01'}, expected_error='invalid_arguments')
        report['invalid_range_rejected'] = True
        report['source_data_modified'] = False
        print(json.dumps(report, indent=2))
    finally:
        for agent in agents:
            admin('--agent-revoke', agent['agent']['id'])


if __name__ == '__main__':
    main()
