# Evaluation Corpora

This directory contains JSON manifests that point to audio files used by the
evaluation harness. The audio files themselves are **not** committed to the repo
(they are large and may carry usage restrictions). Download them separately and
place them next to the corresponding manifest.

---

## Manifests

### `edacc-subset.json` — EdAcc accent robustness (SC-001, SC-005, SC-006)

- **Source**: EdAcc dataset (University of Edinburgh)
- **License**: CC BY 4.0
- **Content**: ~200 utterances from non-native English speakers
  (Italian, Indian/South-Asian, Latino, and native control)
- **Gates**: SC-001 (≥30% rel WER reduction for all L2 groups),
  SC-005 (Italian ≥20%), SC-006 (Indian ≥20%)
- **Audio format**: 16 kHz mono WAV

Download: `scripts/download-edacc-subset.sh` (creates `edacc-subset/` directory)

### `librispeech-subset.json` — LibriSpeech native regression (SC-002, SC-003)

- **Source**: LibriSpeech `test-clean` subset (100 utterances, male + female)
- **License**: CC BY 4.0 (derived from LibriVox)
- **Content**: Native US-English read speech — guards against native WER regression
- **Gates**: SC-002 (≤+2pp native WER delta), SC-003 (p95 latency ≤ 3 000 ms)
- **Audio format**: 16 kHz mono FLAC (WhisperKit handles FLAC natively)

Download: `scripts/download-librispeech-subset.sh`

---

## Manifest JSON format

```json
{
  "name": "edacc-subset",
  "license": "CC-BY-4.0",
  "items": [
    {
      "id": "edacc-it-001",
      "audio_path": "edacc-subset/it/speaker01_utt01.wav",
      "reference_transcript": "The quick brown fox jumps over the lazy dog",
      "accent_group": "italian",
      "speaker_id": "IT-M-01",
      "duration_seconds": 4.2
    }
  ]
}
```

`audio_path` is relative to this `Corpora/` directory.
`accent_group` must be one of: `native`, `italian`, `indian_south_asian`, `latino`, `other`, `unknown`.

---

## Adding new corpora

1. Add a new manifest JSON file here.
2. Update `EvaluationHarness` if the audio format requires a new decoder.
3. Create a new XCTest subclass in `Tests/` following the pattern in
   `EdAccSubsetEvaluation.swift`.
4. Document the license and download instructions in this README.

**Do not commit audio files.** Add `Corpora/**/*.wav`, `Corpora/**/*.flac`,
`Corpora/**/*.mp3` to `.gitignore`.
