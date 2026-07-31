# Privacy

Wispr Free never sends your audio or text anywhere. This page explains what
that means in practice: what stays on your Mac, what's written to disk, what
Accessibility access is used for, and the one optional network call the app
makes.

## What never leaves your Mac

- **Audio** — captured from your microphone, resampled, and transcribed
  entirely on-device with WhisperKit. It's never uploaded. For dictation, by
  default it's discarded immediately after transcription; if you opt into
  "Keep audio with history" (Settings → Privacy, off by default), each
  dictation's raw audio is archived locally — see below. Meeting audio works
  differently: it's always kept on this Mac until the retention limits in
  Settings → Privacy remove it — see "Meetings" below.
- **Transcripts** — both the raw Whisper output and the optional AI-cleaned
  version are produced on-device (WhisperKit and the MLX cleanup model both
  run locally). Neither is sent anywhere.
- **Corrections** — the wrong→right word pairs Wispr Free learns from your
  edits are stored locally and used only to hint the local cleanup model and
  fix future transcripts on-device.

No account, no analytics, no telemetry. Dictation history and correction
learning can both be switched off in Settings → General → Privacy if you'd
rather Wispr Free not keep them at all.

## Files on disk

Wispr Free writes to `~/Library/Application Support/Wispr/`:

| File | Contents | Permissions |
| --- | --- | --- |
| `history.jsonl` | Your dictation history: transcript, target app, timestamp, word count | `0600`, excluded from Time Machine backups |
| `corrections.json` | Learned wrong→right correction pairs | `0600`, excluded from Time Machine backups |
| `audio/<history-entry-UUID>.wav` | Opt-in only ("Keep audio with history", off by default): each dictation's raw audio as 16-bit PCM mono 16 kHz WAV, capped at the last 100 files (oldest evicted first) | `0600`, excluded from Time Machine backups |
| `models/` | Downloaded Whisper, cleanup, and meeting-diarization models | — |
| `vocabulary.json` | Custom words you've added so Whisper spells them right | `0600`, excluded from Time Machine backups |
| `wispr.log` | Diagnostic log: timestamps, model ids, permission and failure reasons. No transcript text, no dictated or meeting content | `0600`, excluded from Time Machine backups |
| `meetings.json` | Meeting metadata, transcripts, summaries | `0600`, excluded from Time Machine backups |
| `meetings/<meeting-UUID>-mic.m4a` and `-system.m4a` | Meeting audio (16 kHz mono AAC) | `0600`, excluded from Time Machine backups — applied once the recording finishes, see "Meetings" below |

`0600` means only your macOS user account can read these files, and macOS's
`isExcludedFromBackup` flag keeps them out of Time Machine. Neither
protection covers backup tools you run yourself (iCloud Drive sync, rsync,
third-party backup software) — if you point one of those at your Application
Support folder, it will pick these files up like any other local file.

Settings (push-to-talk key, selected models, delivery rules, pinned
language, toggles) live in `UserDefaults`, not in these files.

### Purging your data

- **One entry:** open the History window (menu bar → History) and delete it.
  If that entry has archived audio, its WAV file is deleted too.
- **All history:** History window → **Clear History…**. Check "Also forget
  learned corrections" to wipe corrections at the same time. This also
  purges any archived audio.
- **Just corrections:** History window → corrections list → **Forget All**.
- **Archived audio:** turning off "Keep audio with history" (Settings →
  Privacy) immediately deletes every archived WAV file. Settings → Privacy →
  **Delete All Data…** also purges the archive along with history and
  corrections.
- **Meeting recordings:** Settings → Privacy → **Delete All Meetings…**
  deletes every meeting row, transcript, and summary — `meetings.json` is
  overwritten to an empty list, and every `.m4a` track under `meetings/` is
  removed. It refuses while a meeting is recording or being stopped, and
  tells you so rather than deleting some of them; stop the meeting and try
  again. **Delete All Data…** also purges meetings along with history,
  corrections, and archived audio, and refuses on the same condition.
- **Everything, including models:** `brew uninstall --zap wispr-free` if you
  installed via Homebrew, or manually delete
  `~/Library/Application Support/Wispr/` and drag the app to the Trash.

## Meetings

- Recording captures your microphone and everything your Mac is playing,
  which includes the other participants.
- Nothing leaves the Mac. Transcription, diarization, and summarisation all
  run locally.
- The Screen Recording permission is what lets Wispr hear the other
  participants; it is used for audio only, and the video path is a 2×2 pixel
  frame that is never written anywhere.
- Meeting audio is deleted by the retention limits in Privacy, and
  immediately by "Delete All Meetings…" or "Delete All Data…".
- The `0600`-permissions and Time-Machine-exclusion protections in the table
  above are applied to the mic and system-audio tracks only once the
  recording finishes. For the live duration of a meeting those two files sit
  at the default file permissions and remain Time-Machine-eligible. If Wispr
  crashes or is force-quit mid-recording they stay that way until the next
  launch, which tightens them as it reconciles the interrupted meeting.
- **You are responsible for telling the other participants you are
  recording.** Recording consent laws differ by jurisdiction. Wispr does not
  announce itself in the call.
- Diarization and cleanup/summarization models are downloaded from Hugging
  Face on first use — the same one-time model download every other on-device
  feature uses (see "The single optional network call" below). No audio,
  transcript, summary, or note ever goes over the network, during a meeting
  or after one. The once-a-day update check described below is on a timer
  and is not suppressed while a meeting is recording; it sends no meeting
  data, and you can turn it off in Settings → General.

## Accessibility usage

Wispr Free requests Accessibility access to type your dictated text into
whatever app has focus, and to detect the target app for per-app delivery
rules. It reads the focused element at two moments only: when you release
push-to-talk (to check whether you're dictating into a secure field and to
capture the delivery target), and again when the transcript is ready to
deliver moments later (to decide how to insert the text). Outside those two
moments it never scans, reads, or monitors any other app's content, and it
never runs in the background watching what you do.

## Secure input

If the focused element is a secure text field (a password field), dictation
still works, but the result is typed directly into the field — it's never
placed on the general clipboard, never written to history, and no
correction learning happens for it. Wispr Free detects this via the
Accessibility subrole of the focused element at the moment you release
push-to-talk, before recording the history entry.

## The single optional network call

Once a day, Wispr Free checks GitHub for a newer release. When it does,
GitHub sees your IP address and a standard HTTPS request — no audio, text,
or account data is sent. Turn it off in Settings → General
("Automatically check for updates").

The only other network use is downloading models (Whisper, any cleanup model
you select, and the Meetings diarization model, from Hugging Face) the first
time you need them, direct from their hosting source. After that, everything
runs offline.
