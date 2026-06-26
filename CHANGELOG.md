# Changelog

All notable changes to the Salesforce Event Monitor are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- **Event feed is now scrollable and retains up to 100 events.** Previously the
  feed was capped at 15 events with no independent scroll region, so a burst of
  activity pushed events off the bottom of the page. The shell is now bound to
  the viewport and `.event-feed` has its own scrollbar (`min-height: 0` so the
  flex child can scroll); `MAX_EVENTS` was raised from 15 to 100.
  (`streamingMonitor.js`, `streamingMonitor.css`)
