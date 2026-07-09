# Reading cue audio

Drop the breathing-cue voice clips here and they'll be used automatically (the app falls back
to on-device speech if they're missing). After adding files, run `xcodegen generate`.

Expected files (MP3, mono; m4a/wav/caf also accepted):

- `breathe-in.mp3` — spoken "Breathe in" (calm, slow)
- `breathe-out.mp3` — spoken "Breathe out"
- `reading-complete.mp3` — optional soft bell / "Reading complete" close

Generate the voice in ElevenLabs (calm, soft-spoken female; see the prompt shared in chat).
