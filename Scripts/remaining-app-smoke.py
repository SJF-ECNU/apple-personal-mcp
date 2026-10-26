#!/usr/bin/env python3
"""Read actual Notes, Messages and Voice Memos. Prints only counts/status, never contents."""
import base64
import json
import pathlib
import shutil
import subprocess
import uuid

HOST = '/Applications/ApplePersonalMCP.app/Contents/MacOS/ApplePersonalMCPHost'
BRIDGE = '/Applications/ApplePersonalMCP.app/Contents/Helpers/apple-personal-mcp'


def admin(*args):
    p = subprocess.run([HOST, *args], capture_output=True, text=True, timeout=20)
    assert p.returncode == 0, 'Native administration failed'
    return json.loads(p.stdout)


def call(agent, tool, args=None, error=None):
    p = subprocess.run([BRIDGE, '--credential-file', agent['credential_file'], 'call', tool, json.dumps(args or {})], capture_output=True, text=True, timeout=45)
    value = json.loads(p.stdout)
    if error:
        assert value['isError'] and value['body']['error']['code'] == error
    else:
        assert not value['isError'], tool + ': ' + value['body'].get('error', {}).get('code', '')
    return value['body']


def reassemble(agent, tool, id, key='body'):
    offset = 0
    text = ''
    while True:
        row = call(agent, tool, {'id': id, 'body_offset': offset, 'max_chars': 127})
        assert row[key]['offset'] == offset
        text += row[key]['text']
        if row[key]['next_offset'] is None:
            assert len(text) == row[key]['total_scalars']
            return text
        offset = row[key]['next_offset']
        assert offset <= 1000000, 'Large real body requires separate verification'


def main():
    agents = []
    try:
        for app in ['notes', 'messages', 'voice_memos']:
            agents.append(admin('--agent-create', 'APM read validation ' + str(uuid.uuid4()), '--permissions', app + '.read'))
        notes, messages, voice = agents
        report = {}
        report['notes_folders'] = len(call(notes, 'notes_list_folders')['folders'])
        found = call(notes, 'notes_search', {'limit': 10})
        report['notes_total'] = found['total']
        note = next((row for row in found['notes'] if not row['password_protected']), None)
        assert note, 'No readable Notes sample'
        body = reassemble(notes, 'notes_get', note['id'])
        initial = call(notes, 'notes_get', {'id': note['id']})
        assert body.startswith(initial['body']['text'])
        assert call(notes, 'notes_get', {'id': note['id'], 'include_html': True, 'max_chars': 31})['body_view'] == 'original_html'
        assert call(notes, 'notes_search', {'text': 'apm-impossible-' + str(uuid.uuid4()), 'limit': 1})['total'] == 0
        report['notes_plain_and_html_read'] = True
        report['notes_full_body_scalars'] = len(body)
        report['messages_state'] = call(messages, 'system_status')['applications']['messages']
        chats = call(messages, 'messages_list_chats', {'limit': 2})['chats']
        report['chats_page_count'] = len(chats)
        assert chats and call(messages, 'messages_get_thread', {'chat_id': chats[0]['id'], 'limit': 2})['messages']
        counts = {}
        sample = None
        archive_sample = None
        for offset in range(0, 1000, 200):
            rows = call(messages, 'messages_search', {'offset': offset, 'limit': 200})
            for row in rows['messages']:
                counts[row['body_source']] = counts.get(row['body_source'], 0) + 1
                if sample is None and row['preview']:
                    sample = row
                if row['body_source'] == 'typedstream' and row['preview'] and (archive_sample is None or len(row['preview']) > len(archive_sample['preview'])):
                    archive_sample = row
            if not rows['has_more']:
                break
        assert sample
        assert reassemble(messages, 'messages_get', sample['id']).startswith(sample['preview'])
        report['message_body_sources_in_sample'] = counts
        report['messages_full_body_read'] = True
        assert archive_sample, 'No nonempty actual archived-body sample was found'
        archive_body = reassemble(messages, 'messages_get', archive_sample['id'])
        assert archive_body.startswith(archive_sample['preview'])
        report['actual_archived_body_read'] = True
        report['actual_archived_body_scalars'] = len(archive_body)
        archived_detail = call(messages, 'messages_get', {'id': archive_sample['id'], 'max_chars': 1})
        report['archived_sample_attachments'] = len(archived_detail['attachments'])
        for attachment in archived_detail['attachments']:
            if attachment['is_downloaded']:
                asset = call(messages, 'messages_get_attachment', {'id': archive_sample['id'], 'attachment_id': attachment['id']})
                chunk = call(messages, 'assets_read', {'application': 'messages', 'asset_id': asset['asset_id'], 'length': 1024})
                assert len(base64.b64decode(chunk['data_base64'])) == min(1024, asset['size'])
                report['actual_message_attachment_export_bytes'] = asset['size']
                break
        report['archive_validation'] = admin('--inspect-local-sources')['messages_archive_validation']
        call(notes, 'messages_search', {'limit': 1}, error='permission_denied')
        call(messages, 'notes_list_folders', error='permission_denied')
        report['application_scopes_enforced'] = True
        report['voice_state'] = call(voice, 'system_status')['applications']['voice_memos']
        recordings = call(voice, 'voicememos_list', {'limit': 200})['recordings']
        report['recordings_page_count'] = len(recordings)
        report['recording_extensions'] = sorted({row['native_extension'] for row in recordings})
        report['voice_audio_exports'] = 0
        report['original_transcripts_verified'] = 0
        for recording in recordings:
            if not recording['audio_downloaded']:
                call(voice, 'voicememos_get_audio', {'id': recording['id']}, error='not_downloaded')
                call(voice, 'voicememos_get_transcript', {'id': recording['id']}, error='not_downloaded')
                continue
            if report['voice_audio_exports'] == 0:
                asset = call(voice, 'voicememos_get_audio', {'id': recording['id']})
                chunk = call(voice, 'assets_read', {'application': 'voice_memos', 'asset_id': asset['asset_id'], 'length': 1024})
                assert len(base64.b64decode(chunk['data_base64'])) == min(1024, asset['size'])
                report['voice_audio_exports'] += 1
                report['voice_audio_export_bytes'] = asset['size']
            response = subprocess.run([BRIDGE, '--credential-file', voice['credential_file'], 'call', 'voicememos_get_transcript', json.dumps({'id': recording['id']})], capture_output=True, text=True, timeout=45)
            value = json.loads(response.stdout)
            if value['isError']:
                code = value['body']['error']['code']
                report.setdefault('voice_transcript_unavailable', {})[code] = report.setdefault('voice_transcript_unavailable', {}).get(code, 0) + 1
                continue
            assert value['body']['transcript_source'] == 'apple_original_embedded'
            text = reassemble(voice, 'voicememos_get_transcript', recording['id'])
            if not text:
                continue
            report['original_transcript_scalars'] = len(text)
            report['original_transcript_media_extension'] = value['body']['media_extension']
            report['original_transcripts_verified'] += 1
            break
        report['source_data_modified'] = False
        print(json.dumps(report, indent=2))
    finally:
        for agent in agents:
            admin('--agent-revoke', agent['agent']['id'])
            directory = pathlib.Path.home() / 'Library/Application Support/ApplePersonalMCP/Agents' / agent['agent']['id']
            if directory.is_dir():
                shutil.rmtree(directory)


if __name__ == '__main__':
    main()
