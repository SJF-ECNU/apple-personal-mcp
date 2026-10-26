## ADDED Requirements

### Requirement: Official permission-aware reads
The app SHALL expose bounded Calendar and Reminders reads through EventKit, require independent Agent read scopes and report missing system authorization as an error rather than empty results.

#### Scenario: Missing system permission
- **WHEN** an authorized Agent queries a module without full system access
- **THEN** the host returns needs_calendar_permission or needs_reminders_permission and does not prompt on behalf of the Agent

### Requirement: Bounded and complete content
The app SHALL require timezone-qualified event ranges of at most one year, return stable pagination within the observed result set and offer Unicode scalar pages for full event and reminder notes.

#### Scenario: Event range or long notes
- **WHEN** a client uses an invalid range or requests a long note
- **THEN** invalid ranges are rejected and long notes include a continuation offset without silent truncation

### Requirement: Actual verification
The app SHALL distinguish system permission denial, zero local objects and successful real reads in its verification record.

#### Scenario: User has not granted access
- **WHEN** the system authorization is pending
- **THEN** the actual-read task remains incomplete
