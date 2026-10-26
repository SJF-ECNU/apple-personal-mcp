#!/usr/bin/env python3
"""Real installed-app validation. Creates/revokes only its own temporary Agent registrations.
No external mail is sent or modified. Only counts and verification booleans are printed.
"""
import concurrent.futures
import datetime
import json
import os
import pathlib
import select
import subprocess
import time
import uuid

HOST = '/Applications/ApplePersonalMCP.app/Contents/MacOS/ApplePersonalMCPHost'
BRIDGE = '/Applications/ApplePersonalMCP.app/Contents/Helpers/apple-personal-mcp'
SUPPORT = pathlib.Path.home() / 'Library/Application Support/ApplePersonalMCP'


def administer(*args):
    result = subprocess.run([HOST, *args], capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError('Native Agent administration failed')
    return json.loads(result.stdout)


class Client:
    def __init__(self, credential_file):
        self.process = subprocess.Popen([BRIDGE, '--credential-file', credential_file], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.counter = 0
        initialized = self.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                                   'clientInfo': {'name': 'multi-agent-validation', 'version': '1'}})
        self.negotiated_protocol = initialized['result']['protocolVersion']
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n')
        self.process.stdin.flush()

    def request(self, method, params):
        self.counter += 1
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': self.counter, 'method': method, 'params': params}) + '\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            readable, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))
            if not readable:
                break
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError('MCP client terminated unexpectedly')
            response = json.loads(line)
            if response.get('id') == self.counter:
                return response
        raise TimeoutError(method)

    def tools(self):
        response = self.request('tools/list', {})
        assert 'result' in response, 'Tool discovery failed'
        return {item['name'] for item in response['result']['tools']}

    def call(self, name, args=None, error=None):
        response = self.request('tools/call', {'name': name, 'arguments': args or {}})
        assert 'result' in response, 'Tool invocation failed at protocol level'
        result = response['result']
        value = result['structuredContent']
        if error:
            assert result['isError'] and value['error']['code'] == error, 'Unexpected authorization result'
        else:
            assert not result.get('isError'), 'Tool returned an unexpected error'
        return value

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()


def main():
    registered = []
    clients = []
    report = {}
    try:
        for label, grants in [('reader', 'mail.read'), ('writer', 'mail.read,mail.write')]:
            registered.append(administer('--agent-create', 'APM validation ' + label + ' ' + str(uuid.uuid4()), '--permissions', grants))
        a, b = [Client(record['credential_file']) for record in registered]
        clients.extend([a, b])
        ids = {item['agent']['id'] for item in registered}
        assert a.process.pid != b.process.pid
        assert 'mail_create_draft' not in a.tools() and 'mail_create_draft' in b.tools()
        assert 'mail_send_draft' not in b.tools()
        report['independent_clients'] = 2
        report['distinct_tool_permissions'] = True
        report['reader_cannot_create_draft'] = a.call('mail_create_draft', {'subject': 'must not create', 'body': 'must not create'}, error='permission_denied')['error']['code'] == 'permission_denied'
        status = a.call('system_status')
        assert status['agent']['id'] == registered[0]['agent']['id']
        assert status['applications']['mail']['state'] == 'ready'
        report['mail_ready'] = True
        report['accounts'] = len(a.call('mail_list_accounts')['accounts'])
        report['mailboxes'] = len(b.call('mail_list_mailboxes')['mailboxes'])

        def read(client):
            for _ in range(2):
                result = client.call('mail_search', {'body': 'apm-' + str(uuid.uuid4()), 'scan_limit': 100})
                assert result['scanned'] > 0
            return True

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            assert all(pool.map(read, [a, b]))
        entries = [json.loads(line) for line in (SUPPORT / 'activity.jsonl').read_text().splitlines()]
        spans = {}
        for entry in entries:
            if entry.get('agent_id') not in ids or entry.get('tool') != 'mail_search':
                continue
            span = spans.setdefault(entry['request_id'], {'agent': entry['agent_id']})
            if entry['phase'] in ('started', 'finished'):
                span[entry['phase']] = datetime.datetime.fromisoformat(entry['time'].replace('Z', '+00:00'))
        complete = [span for span in spans.values() if 'started' in span and 'finished' in span]
        overlap = any(x['agent'] != y['agent'] and max(x['started'], y['started']) < min(x['finished'], y['finished'])
                      for x in complete for y in complete)
        assert overlap, 'No actual cross-Agent read overlap observed'
        report['actual_parallel_reads_observed'] = True
        report['completed_body_scans'] = len(complete)

        for row in a.call('mail_search', {'limit': 50})['messages']:
            detail = a.call('mail_get', {'id': row['id'], 'max_chars': 1})
            attachments = [item for item in detail['attachments'] if item['isDownloaded']]
            if not attachments:
                continue
            asset = a.call('mail_get_attachment', {'id': row['id'], 'part_id': attachments[0]['partID']})
            a.call('assets_read', {'asset_id': asset['asset_id'], 'length': 16})
            b.call('assets_read', {'asset_id': asset['asset_id'], 'length': 16}, error='not_found')
            report['real_attachment_isolated'] = True
            break
        assert report.get('real_attachment_isolated')

        administer('--agent-update', registered[1]['agent']['id'], '--permissions', 'calendar.read')
        assert b.tools() == {'system_status', 'calendar_list', 'calendar_search', 'calendar_get'}
        b.call('mail_search', {'limit': 1}, error='permission_denied')
        denied_status = b.call('system_status')
        assert 'messages' not in denied_status['applications']['mail']
        report['live_downgrade_enforced'] = True
        administer('--agent-revoke', registered[1]['agent']['id'])
        b.call('system_status', error='invalid_credentials')
        report['connected_agent_revocation_enforced'] = True

        # Re-run the original real-read regression through authenticated access.
        smoke = subprocess.run(['python3', str(pathlib.Path(__file__).with_name('smoke.py')), '--credential-file', registered[0]['credential_file']], capture_output=True, text=True, timeout=60)
        assert smoke.returncode == 0, 'Authenticated Mail regression failed'
        report['mail_regression'] = json.loads(smoke.stdout)

        for client in clients:
            client.close()
        clients.clear()
        subprocess.run(['launchctl', 'kickstart', '-k', f'gui/{os.getuid()}/com.shjf.apple-personal-mcp.service'], check=True, capture_output=True, timeout=15)
        a = Client(registered[0]['credential_file']); clients.append(a)
        assert a.call('system_status')['agent']['id'] == registered[0]['agent']['id']
        records = administer('--agent-list')
        assert next(item for item in records if item['id'] == registered[1]['agent']['id'])['revoked']
        report['permissions_survive_restart'] = True
        report['revocation_survives_restart'] = True
        report['external_send_attempted'] = False
        print(json.dumps(report, indent=2))
    finally:
        for client in clients:
            client.close()
        for record in registered:
            administer('--agent-revoke', record['agent']['id'])
            # Remove only the temporary validation Agent's app-owned exports/state.
            directory = SUPPORT / 'Agents' / record['agent']['id']
            if directory.is_dir():
                import shutil
                shutil.rmtree(directory)


if __name__ == '__main__':
    main()
