#!/usr/bin/env python3
"""Two real stdio MCP clients read all six applications, without Apple-data writes."""
import concurrent.futures
import importlib.util
import json
import pathlib
import shutil
import uuid

spec = importlib.util.spec_from_file_location('multi', pathlib.Path(__file__).with_name('multi-agent-smoke.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def main():
    agents = []
    clients = []
    try:
        grants = ','.join(app + '.read' for app in ['mail', 'calendar', 'reminders', 'notes', 'messages', 'voice_memos'])
        for _ in range(2):
            agents.append(m.administer('--agent-create', 'APM six-app client ' + str(uuid.uuid4()), '--permissions', grants))
            clients.append(m.Client(agents[-1]['credential_file']))

        def read(client):
            status = client.call('system_status')
            assert all(v['state'] == 'ready' for v in status['applications'].values())
            result = {'protocol': client.negotiated_protocol, 'applications': len(status['applications'])}
            assert client.call('mail_list_accounts')['accounts']
            mail = client.call('mail_search', {'limit': 1})['messages'][0]
            assert client.call('mail_get', {'id': mail['id']})['body_downloaded']
            assert client.call('calendar_list')['items']
            assert client.call('reminders_list_lists')['items']
            note = next(x for x in client.call('notes_search', {'limit': 10})['notes'] if not x['password_protected'])
            assert 'body' in client.call('notes_get', {'id': note['id']})
            chat = client.call('messages_list_chats', {'limit': 1})['chats'][0]
            assert client.call('messages_get_thread', {'chat_id': chat['id'], 'limit': 1})['messages']
            recording = next(x for x in client.call('voicememos_list', {'limit': 200})['recordings'] if x['audio_downloaded'])
            asset = client.call('voicememos_get_audio', {'id': recording['id']})
            resource = client.request('resources/read', {'uri': asset['uri']})
            if asset['size'] <= 524288:
                assert resource['result']['contents']
            else:
                assert resource.get('error') or resource.get('result', {}).get('isError')
            assert client.call('assets_read', {'application': 'voice_memos', 'asset_id': asset['asset_id'], 'length': 16})['data_base64']
            assert client.request('prompts/list', {})['result']['prompts']
            result['six_application_reads'] = True
            result['resource_and_prompts'] = True
            return result

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            report = list(pool.map(read, clients))
        print(json.dumps({'independent_stdio_clients': len(clients), 'clients': report}, indent=2))
    finally:
        for client in clients:
            client.close()
        for agent in agents:
            m.administer('--agent-revoke', agent['agent']['id'])
            folder = m.SUPPORT / 'Agents' / agent['agent']['id']
            if folder.is_dir():
                shutil.rmtree(folder)


if __name__ == '__main__':
    main()
