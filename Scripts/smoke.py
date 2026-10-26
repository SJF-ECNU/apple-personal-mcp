#!/usr/bin/env python3
"""Exercise the installed signed bridge and native host. Never prints personal content."""
import argparse
import base64
import json
import select
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--credential-file', required=True, help='Private Agent credential file created by the native app')
parser.add_argument('--draft', action='store_true', help='Create/update an unsent, recipient-free test draft')
options = parser.parse_args()
binary = '/Applications/ApplePersonalMCP.app/Contents/Helpers/apple-personal-mcp'
process = subprocess.Popen([binary, '--credential-file', options.credential_file, '--read-only'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
counter = 0
report = {}

def request(method, params):
    global counter
    counter += 1
    process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': counter, 'method': method, 'params': params}) + '\n')
    process.stdin.flush()
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            break
        line = process.stdout.readline()
        if not line:
            raise RuntimeError('MCP process exited: ' + process.stderr.read())
        response = json.loads(line)
        if response.get('id') == counter:
            if 'error' in response:
                raise RuntimeError(response['error'])
            return response['result']
    raise TimeoutError(method)

def call(name, args=None):
    response = request('tools/call', {'name': name, 'arguments': args or {}})
    value = response.get('structuredContent') or json.loads(response['content'][0]['text'])
    if response.get('isError'):
        raise RuntimeError(value)
    return value

try:
    init = request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'apm-local-smoke', 'version': '1'}})
    report['protocol_version'] = init['protocolVersion']
    process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n'); process.stdin.flush()
    tools = request('tools/list', {})['tools']
    assert not any(t['name'] == 'mail_create_draft' for t in tools)
    report['readonly_tool_count'] = len(tools)
    denied = request('tools/call', {'name': 'mail_create_draft', 'arguments': {'subject': 'must-not-create', 'body': 'must-not-create'}})
    assert denied['isError'] and denied['structuredContent']['error']['code'] == 'read_only'
    report['readonly_enforced'] = True
    status = call('system_status')
    report['mail_state'] = status['applications']['mail']['state']
    assert report['mail_state'] == 'ready', status['applications']['mail']
    report['local_message_count'] = status['applications']['mail']['messages']
    report['accounts'] = len(call('mail_list_accounts')['accounts'])
    report['mailboxes'] = len(call('mail_list_mailboxes')['mailboxes'])
    report['overview_latest'] = len(call('mail_overview')['latest'])
    rows = call('mail_search', {'limit': 5})['messages']
    assert rows
    first = rows[0]
    detail = call('mail_get', {'id': first['id'], 'max_chars': 100})
    report['body_downloaded'] = detail['body_downloaded']
    report['body_page_scalars'] = len(detail.get('body', {}).get('text', ''))
    next_offset = detail.get('body', {}).get('next_offset')
    if next_offset is not None:
        continuation = call('mail_get', {'id': first['id'], 'body_offset': next_offset, 'max_chars': 100})
        assert continuation['body']['offset'] == next_offset
        report['body_continuation'] = True
    after = call('mail_get_many', {'ids': [first['id']]})['messages'][0]
    assert after['is_read'] == first['is_read']
    report['read_did_not_mark_read'] = True
    unread_boxes = [b for b in call('mail_list_mailboxes')['mailboxes'] if b['role'] == 'inbox' and b['unreadCount'] > 0]
    if unread_boxes:
        unread = call('mail_search', {'mailbox_id': str(unread_boxes[0]['id']), 'unread': True, 'limit': 1})['messages']
        if unread:
            assert unread[0]['is_read'] is False
            call('mail_get', {'id': unread[0]['id'], 'max_chars': 100})
            reread = call('mail_get_many', {'ids': [unread[0]['id']]})['messages'][0]
            assert reread['is_read'] is False
            report['real_unread_inbox_message_stayed_unread'] = True
    report['thread_rows'] = len(call('mail_get_thread', {'id': first['id']})['messages'])
    report['batch_rows'] = len(call('mail_get_many', {'ids': [r['id'] for r in rows]})['messages'])
    scan = call('mail_search', {'body': 'apm-nonexistent-' + str(uuid.uuid4()), 'scan_limit': 3})
    report['body_scan_checked'] = scan['scanned']
    report['body_scan_complete'] = scan['search_complete']
    assert not scan['search_complete'] and scan['next_scan_offset'] is not None
    # Find one already downloaded attachment; content stays in memory, never in this report.
    candidates = call('mail_search', {'limit': 50})['messages']
    for row in candidates:
        d = call('mail_get', {'id': row['id'], 'max_chars': 1})
        attachments = [a for a in d['attachments'] if a['isDownloaded']]
        if not attachments:
            continue
        asset = call('mail_get_attachment', {'id': row['id'], 'part_id': attachments[0]['partID']})
        chunk = call('assets_read', {'asset_id': asset['asset_id'], 'offset': 0, 'length': 1024})
        assert len(base64.b64decode(chunk['data_base64'])) == min(asset['size'], 1024)
        report['attachment_export_bytes'] = asset['size']
        break
    else:
        report['attachment_export'] = 'no_downloaded_attachment_in_first_50'
finally:
    process.stdin.close()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.terminate(); process.wait(timeout=5)

if options.draft:
    def native(name, args):
        result = subprocess.run([binary, '--credential-file', options.credential_file, 'call', name, json.dumps(args)], capture_output=True, text=True, timeout=45)
        payload = json.loads(result.stdout)
        if payload['isError']:
            raise RuntimeError(payload['body'])
        return payload['body']
    title = 'APM local verification ' + str(uuid.uuid4())
    draft = native('mail_create_draft', {'subject': title, 'body': 'Local MCP validation. No recipients; do not send.', 'to': []})
    assert draft['to'] == [] and draft['subject'] == title
    updated = native('mail_update_draft', {'draft_id': draft['draft_id'], 'body': 'Updated locally through official Apple Events. Not sent.'})
    reread = native('mail_get_draft', {'draft_id': draft['draft_id']})
    assert reread['body'] == updated['body'] and not reread['sent'] and reread['to'] == []
    report['draft_create_update_readback'] = True
    report['unsent_test_draft_id'] = draft['draft_id']
    report['external_send_attempted'] = False

print(json.dumps(report, ensure_ascii=False, indent=2))
