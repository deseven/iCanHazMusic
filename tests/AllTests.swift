// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing

/// Parent suite for all tests in this target.
///
/// The stores (`ConfigStore`, `PlaylistStore`, `ImportSession`) are main-actor bound, and many tests touch the
/// disk or spin up AVFoundation readers. Running the whole tree serialized on the main actor (nested suites
/// inherit both through `extension AllTests`) keeps that predictable.
///
/// Audio/image fixtures come from `tests/prepare-fixtures.sh` (needs ffmpeg); tests that use them fail with a
/// hint if they haven't been generated.
@MainActor
@Suite(.serialized)
enum AllTests {}
