# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- An ElevenLabs voice that needs a paid plan, such as a Voice Library voice on a free plan, now says so. Before, ReGlass
  reported that the character quota was used up.

## [0.1.0] - 2026-11-23

### Added

- Setup for Ray-Ban Meta Clubmaster (Audio) using Meta's signed hand-over, with encrypted Bluetooth, background
  reconnection and battery, case, charging and wearing status.
- A voice assistant with "Hey Meta" and touch-and-hold activation, streaming replies, follow-ups, interruption
  during playback and typed requests.
- Claude answers with web search and a model picker in **Settings → Assistant → Model**. Choose Haiku 5.5
  (the default), Sonnet 5.5, Opus 5.5 or Fable 5.2.
- On-device Apple speech recognition and voice by default, with optional ElevenLabs Scribe and voices. An
  experimental live interpreter translates speech in about 30 languages into English.
- Chats, notes, reminders and lists with categories, search, Recently Deleted and optional iCloud sync for the
  library.
- Connectors for glasses timers, reminders and lists, notes, Calendar, Alarms, Apple Music and Weather.
- Factory wake word downloads and imports, with a separate confirmation before installation.
- Signed firmware updates from Meta over Bluetooth for the Clubmaster (Audio), with progress in the app.
