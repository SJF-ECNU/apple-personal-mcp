## ADDED Requirements

### Requirement: Official authorized mutations
The service SHALL mutate Calendar, Reminders and Notes through official APIs, serialize mutations by application and reject stale or unsupported targets without modifying private databases.

#### Scenario: Concurrent stale update
- **WHEN** a caller supplies an expected native modification value that no longer matches
- **THEN** the update fails before mutation

### Requirement: Confirmed external effects
Messages sends and irreversible deletes SHALL require native human confirmation and fresh authorization. Sends SHALL retain global operation uniqueness and owner isolation.

#### Scenario: Unknown send result
- **WHEN** dispatch may have occurred without a reply
- **THEN** the record remains unknown and repeat requests do not resubmit

### Requirement: Local generated transcription jobs
Explicit transcription SHALL run locally, preserve original media/transcripts, persist owner-scoped job state and expose full generated text with source labels and cancellation.

#### Scenario: Restart during processing
- **WHEN** the host restarts with an unfinished job
- **THEN** the job is interrupted and is not silently restarted

### Requirement: Honest recording controls
Recording controls SHALL use verified public actions and reject unknown ownership or unavailable actions.

#### Scenario: Missing stop action
- **WHEN** the platform has no configured verified stop action
- **THEN** the service reports unsupported or not configured and does not stop an arbitrary recording

### Requirement: Authorized resources and cleanup
MCP resources and prompts SHALL be optional and owner scoped. Cleanup SHALL remove only expired app-owned derived files.

#### Scenario: Revoked resource scope
- **WHEN** an Agent loses the source application's read scope
- **THEN** resource listing and reads no longer expose that application's exports
