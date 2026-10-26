## ADDED Requirements

### Requirement: Independent native Agent enrollment
The app SHALL create separate random credentials for each Agent, manage per-application read/write/send permissions and revoke access without exposing enrollment or permission modification through MCP. The product SHALL use the bundled native stdio executable without an npm package.

#### Scenario: Missing or invalid credentials
- **WHEN** a client has no credentials or supplies incorrect credentials
- **THEN** the host denies all data access and tool discovery

### Requirement: Live authorization and isolation
The host SHALL validate permissions for tool discovery and every invocation, including queued execution, isolate exported assets and operation records by Agent and retain XPC signature/user verification.

#### Scenario: Revoke a connected Agent
- **WHEN** a previously connected Agent is revoked or downgraded
- **THEN** its next request and queued work use the updated permissions without a service restart

#### Scenario: Other Agent resource
- **WHEN** an authenticated Agent requests another Agent's asset or operation ID
- **THEN** no resource content or operation state is returned

### Requirement: Bounded concurrency
The host SHALL permit bounded parallel reads and serialize official automation per application. Each concurrent request SHALL use its own source connection and preserve content-free attributable activity records.

#### Scenario: Parallel readers and serialized automation
- **WHEN** two Agents read while official Mail operations are queued
- **THEN** reads can overlap, Mail automation calls do not overlap and already queued revoked work is denied before execution

### Requirement: Evidence from the installed app
The implementation SHALL validate two independent MCP clients against the installed signed host and report unimplemented applications separately.

#### Scenario: Real local verification
- **WHEN** the implementation is delivered
- **THEN** recorded results distinguish actual Mail multi-client validation, synthetic scheduling tests and the remaining five applications
