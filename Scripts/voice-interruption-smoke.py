#!/usr/bin/env python3
"""Native jobs: running cancellation, permission revocation and service restart."""
import importlib.util
import json
import os
import pathlib
import subprocess
import time

spec = importlib.util.spec_from_file_location('reads', pathlib.Path(__file__).with_name('remaining-app-smoke.py'))
reads = importlib.util.module_from_spec(spec); spec.loader.exec_module(reads)
root = pathlib.Path.home() / 'Library/Application Support/ApplePersonalMCP'
path = root / 'Validation/voice-jobs.json'; manifest = json.loads(path.read_text()); agent = manifest['agent']
def call(a, n, args=None): return reads.call(a, n, args)
sample = min((r for r in call(agent, 'voicememos_list', {'limit': 200})['recordings'] if r['audio_downloaded'] and r['duration_seconds'] > 180), key=lambda r: r['duration_seconds'])
def start(a):
    j = call(a, 'voicememos_transcribe', {'id': sample['id'], 'locale': 'zh-CN'})
    manifest['jobs'].append(j['job_id']); path.write_text(json.dumps(manifest, indent=2))
    for _ in range(50):
        state = call(a, 'voicememos_job_get', {'job_id': j['job_id']})
        if state['status'] != 'queued': break
        time.sleep(0.1)
    assert state['status'] == 'running', 'No actual running task was observed: ' + state['status'] + ':' + str(state['error'])
    return j['job_id']
def terminal(id, status):
    for _ in range(30):
        state = json.loads((root / 'Jobs' / (id + '.json')).read_text())
        if state['status'] == status and not list((root / 'Jobs' / id).glob('input*')): return state
        time.sleep(1)
    raise AssertionError('Job did not stop and discard work audio')
id = start(agent)
assert call(agent, 'voicememos_job_cancel', {'job_id': id})['status'] == 'cancelled'
terminal(id, 'cancelled'); manifest['checks']['actual_running_task_cancelled'] = True
revoked = reads.admin('--agent-create', 'APM job revocation validation', '--permissions', 'voice_memos.read,voice_memos.write')
try:
    id = start(revoked); reads.admin('--agent-revoke', revoked['agent']['id'])
    assert terminal(id, 'failed')['error'] == 'invalid_credentials'
    manifest['checks']['actual_running_task_revocation_stopped'] = True
finally:
    reads.admin('--agent-revoke', revoked['agent']['id'])
id = start(agent)
subprocess.run(['launchctl', 'kickstart', '-k', f'gui/{os.getuid()}/com.shjf.apple-personal-mcp.service'], check=True, capture_output=True)
assert call(agent, 'voicememos_job_get', {'job_id': id})['status'] == 'interrupted'
terminal(id, 'interrupted'); manifest['checks']['actual_running_task_restart_interrupted'] = True
manifest['interruption_sample_duration_seconds'] = sample['duration_seconds']; path.write_text(json.dumps(manifest, indent=2))
print(json.dumps({'checks': manifest['checks'], 'sample_duration_seconds': sample['duration_seconds']}, indent=2))
