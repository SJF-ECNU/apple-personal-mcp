#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import time

spec = importlib.util.spec_from_file_location('reads', pathlib.Path(__file__).with_name('remaining-app-smoke.py'))
reads = importlib.util.module_from_spec(spec); spec.loader.exec_module(reads)
root = pathlib.Path.home() / 'Library/Application Support/ApplePersonalMCP/Validation'
root.mkdir(mode=0o700, exist_ok=True)
path = root / 'voice-jobs.json'
assert not path.exists(), 'Existing jobs must be reviewed before a new validation run'
agent = reads.admin('--agent-create', 'APM voice task validation', '--permissions', 'voice_memos.read,voice_memos.write')
other = reads.admin('--agent-create', 'APM voice isolated reader', '--permissions', 'voice_memos.read')
manifest = {'agent': agent, 'other': other, 'jobs': [], 'checks': {}}
def save():
    path.write_text(json.dumps(manifest, indent=2)); path.chmod(0o600)
def call(n, a=None, error=None): return reads.call(agent, n, a, error)
def start(n, a):
    row = call(n, a); manifest['jobs'].append(row['job_id']); save(); return row
def wait(id):
    deadline = time.monotonic() + 1800
    while time.monotonic() < deadline:
        row = call('voicememos_job_get', {'job_id': id})
        if row['status'] not in ['queued', 'running']: return row
        time.sleep(2)
    raise TimeoutError('Native media task did not finish within 30 minutes')
save()
recordings = call('voicememos_list', {'limit': 200})['recordings']
sample = min((r for r in recordings if r['audio_downloaded'] and 8 < r['duration_seconds'] < 180), key=lambda r: r['duration_seconds'])
manifest['sample_duration_seconds'] = sample['duration_seconds']; save()
unsupported = start('voicememos_transcribe', {'id': sample['id'], 'locale': 'zz-ZZ'})
assert wait(unsupported['job_id'])['error'] == 'unsupported_locale'
manifest['checks']['unsupported_locale_explicit'] = True; save()
transcript = start('voicememos_transcribe', {'id': sample['id'], 'locale': 'zh-CN', 'download_models': True})
reads.call(other, 'voicememos_job_get', {'job_id': transcript['job_id']}, 'not_found')
cancelled = start('voicememos_convert', {'id': sample['id']})
assert call('voicememos_job_cancel', {'job_id': cancelled['job_id']})['status'] == 'cancelled'
assert call('voicememos_job_get', {'job_id': cancelled['job_id']})['status'] == 'cancelled'
manifest['checks']['cross_agent_job_isolation'] = True
manifest['checks']['queued_job_cancelled'] = True; save()
conversion = start('voicememos_convert', {'id': sample['id']})
result = wait(transcript['job_id'])
manifest['transcription_status'] = result['status']; manifest['transcription_error'] = result['error']; save()
assert result['status'] == 'succeeded', 'Native transcription did not succeed: ' + str(result['error'])
text = ''; offset = 0
while True:
    row = call('voicememos_job_get', {'job_id': transcript['job_id'], 'body_offset': offset, 'max_chars': 7})
    text += row['body']['text']
    if row['body']['next_offset'] is None: break
    offset = row['body']['next_offset']
assert len(text) == row['body']['total_scalars'] and text
manifest['checks']['actual_generated_transcript_full_paging'] = True
manifest['generated_transcript_scalars'] = len(text)
converted = wait(conversion['job_id'])
assert converted['status'] == 'succeeded', 'Native conversion did not succeed'
manifest['checks']['actual_m4a_conversion'] = True
manifest['conversion_bytes'] = converted['result']['size']; save()
print(json.dumps({k: v for k, v in manifest.items() if k not in ['agent', 'other', 'jobs']}, indent=2))
