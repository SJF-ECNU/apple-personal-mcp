## ADDED Requirements

### Requirement: Source-aware full local reads
The app SHALL expose independently authorized Notes, Messages and Voice Memos reads using official interfaces where available and read-only private data otherwise.

#### Scenario: Unsupported or unavailable content
- **WHEN** a body or transcript is not locally downloaded or its format is unsupported
- **THEN** the result explicitly reports unavailability or incomplete coverage rather than an empty successful full text

### Requirement: Existing recording and original transcript
Voice Memos SHALL expose original available audio and original transcript text with source attribution and continuation when supported by verified local formats.

#### Scenario: Existing transcript
- **WHEN** an original transcript is retrieved
- **THEN** the full original text can be reassembled from pages and is not replaced by newly generated text

### Requirement: Actual sample verification
The verification record SHALL distinguish successful actual reads, synthetic parser coverage and missing real samples.

#### Scenario: No matching real sample
- **WHEN** the machine has no sample for a required private format
- **THEN** that sample validation remains incomplete
