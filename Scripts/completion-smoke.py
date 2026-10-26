#!/usr/bin/env python3
"""Resume private completion validation. Uses only the manifest's owned test message.
No external sends; private contents and credentials never appear in the report.
"""
import argparse
import base64
import importlib.util
import json
import pathlib
import time
import uuid


def load(name):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', required=True)
    args = parser.parse_args()
    path = pathlib.Path(args.manifest)
    state = json.loads(path.read_text())
    r = load('remaining-app-smoke')
    m = load('multi-agent-smoke')
    agent = state['agent']
    checks = state['checks']

    def save():
        path.write_text(json.dumps(state, ensure_ascii=False))
        path.chmod(0o600)

    # This exact synthetic source was uploaded in the preparation step.
    expected = ('APM synthetic attachment 中文😀\n' * 40000).encode()
    rows = r.call(agent, 'mail_search', {'subject': 'APM completion verified attachment', 'limit': 20})['messages']
    assert len(rows) == 1
    detail = r.call(agent, 'mail_get', {'id': rows[0]['id']})
    attachment = next(x for x in detail['attachments'] if x['filename'] == 'APM-test.txt')
    asset = r.call(agent, 'mail_get_attachment', {'id': rows[0]['id'], 'part_id': attachment['partID']})
    data = bytearray()
    offset = 0
    while True:
        chunk = r.call(agent, 'assets_read', {'application': 'mail', 'asset_id': asset['asset_id'], 'offset': offset, 'length': 524288})
        data.extend(base64.b64decode(chunk['data_base64']))
        if chunk['next_offset'] is None:
            break
        offset = chunk['next_offset']
    assert bytes(data) == expected
    checks['actual_draft_attachment_full_bytes'] = len(data)
    save()

    message_id = state['mail_test_message_id']
    original = r.call(agent, 'mail_get', {'id': message_id})
    assert original['subject'] == 'Apple Personal MCP 本机连通测试'
    flag = original['flagged']
    try:
        first = r.call(agent, 'mail_set_flags', {'id': message_id, 'flagged': not flag})
        second = r.call(agent, 'mail_set_flags', {'id': message_id, 'flagged': flag})
        r.call(agent, 'mail_undo_change', {'change_id': first['change_id']}, error='change_conflict')
        assert r.call(agent, 'mail_undo_change', {'change_id': second['change_id']})['status'] == 'undone'
        assert r.call(agent, 'mail_undo_change', {'change_id': first['change_id']})['status'] == 'undone'
        checks['actual_undo_conflict'] = True
        save()

        # A real MCP notification must propagate through the stdio SDK and XPC.
        batch = str(uuid.uuid4())
        state['cancel_batch_id'] = batch
        save()
        client = m.Client(agent['credential_file'])
        try:
            client.counter += 1
            request_id = client.counter
            client.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': request_id, 'method': 'tools/call', 'params': {'name': 'mail_batch_modify', 'arguments': {'batch_id': batch, 'items': [{'id': message_id, 'flagged': bool(i % 2)} for i in range(20)]}}}) + '\n')
            client.process.stdin.flush()
            time.sleep(0.2)
            client.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': request_id, 'reason': 'owned test cancellation'}}) + '\n')
            client.process.stdin.flush()
            progress = r.call(agent, 'mail_batch_get', {'batch_id': batch})
            assert progress['status'] == 'stopped', progress['status']
            assert 0 < len(progress['results']) < 20
            last = progress['results'][-1]
            assert last.get('error', {}).get('code') == 'cancelled' or last.get('result', {}).get('status') == 'unknown'
            again = r.call(agent, 'mail_batch_modify', {'batch_id': batch, 'items': [{'id': message_id, 'flagged': flag}]})
            assert again == progress
            checks['actual_mcp_cancel_stopped_batch'] = True
            checks['batch_results_before_stop'] = len(progress['results'])
            checks['batch_retry_no_reexecution'] = True
            save()
        finally:
            client.close()
    finally:
        r.call(agent, 'mail_set_flags', {'id': message_id, 'flagged': flag})
    print(json.dumps(checks, indent=2))


if __name__ == '__main__':
    main()
