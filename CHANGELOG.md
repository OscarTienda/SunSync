# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.3] - 2026-07-22

### Fixed
- Virtual monitor scripts now detect qdbus6 or qdbus depending on what the
  distro ships (Fedora and Nobara only have qdbus). Thanks @Igna-Olivares.

## [0.2.2] - 2026-06-30

### Fixed
- Virtual monitor start script now correctly floors decimal FPS values from
  `SUNSHINE_CLIENT_FPS` before arithmetic, preventing a syntax error when the
  client reports a non-integer frame rate (e.g. `59.94`). Thanks @Klbgr.

## [0.2.1] - 2026-06-07

### Fixed
- GUI now detects the active backend (Sunshine or Apollo) instead of assuming
  Sunshine. Previously the GUI always used Sunshine's HTTP Basic auth, so Apollo
  users hit "Login failed" with correct credentials, and Sunshine/Apollo config
  was read from the wrong location (covers, API key, saved connection,
  credentials). Affected flatpak Sunshine installs too.
- A running Apollo instance no longer shows as "Sunshine not running" in the
  status bar.
- First-run detection is keyed on the active backend, so Apollo users are no
  longer shown the setup wizard on every launch.
- The connection host field now prefills `localhost` instead of relying on the
  placeholder, which looked like an already-set value and led to empty-host
  login failures.
- Status messages, dialogs and the login window now name the active backend
  (Sunshine/Apollo) instead of always saying "Sunshine".

## [0.2.0] - 2026-06-07

### Added
- `list` and `remove` CLI subcommands to inspect and delete configured apps.
- `--version` flag.
- Virtual-monitor scripts can override which outputs to disable via an
  environment variable.

### Fixed
- Hardened API requests, Steam Flatpak cover lookup, batch deduplication and the
  Bottles launch command.

## [0.1.0]

- Initial release.

[0.2.3]: https://github.com/OscarTienda/SunSync/releases/tag/v0.2.3
[0.2.2]: https://github.com/OscarTienda/SunSync/releases/tag/v0.2.2
[0.2.1]: https://github.com/OscarTienda/SunSync/releases/tag/v0.2.1
[0.2.0]: https://github.com/OscarTienda/SunSync/releases/tag/v0.2.0
[0.1.0]: https://github.com/OscarTienda/SunSync/releases/tag/v0.1.0
