# Discord Rich Presence

`DiscordPresence` (`src/Core/Integrations/Discord`) shows the playing track on the user's Discord profile. Opt-in
(Preferences > Integrations, config `integrations.discord.enabled`).

## Why local IPC

Discord offers three ways in: the Social SDK (a closed-source dylib plus OAuth, made for games), the Embedded App SDK
(activities inside Discord, not relevant) and the local RPC socket of the desktop client. Setting an activity through
the socket needs no login and no dependency, only the application ID in the handshake, so that is what the app uses.
The price is that it works only with the Discord desktop app running on the same Mac (not the web client), and only
for a non-sandboxed app (a sandboxed one gets a different `TMPDIR` and can't see the socket).

## Protocol

- Socket: `discord-ipc-{0...9}` in `$XDG_RUNTIME_DIR`, `$TMPDIR`, `$TMP`, `$TEMP` or `/tmp`, the first one that
  takes a connection (`DiscordIPCConnection.socketPaths`). Several Discord instances (stable, PTB, Canary) take the
  next free number.
- Frame: opcode (UInt32 LE), payload length (UInt32 LE), JSON. Opcodes: 0 handshake, 1 frame, 2 close, 3 ping,
  4 pong (`DiscordIPCFrame`).
- Handshake `{"v": 1, "client_id": "<app ID>"}`; Discord answers with a `READY` dispatch, or with a close frame and the
  reason (`Invalid Client ID`, 4000).
- `SET_ACTIVITY` with `pid` and `activity`; without `activity` it clears it. Closing the socket (the app quits)
  clears it as well, so nothing has to be done at quit.
- Limits: texts 2...128 characters (`DiscordActivity.field` pads or cuts them), about 5 updates per 20 seconds
  (`DiscordPresence.minSendInterval`).

## What is shown

A Listening activity (`type` 2) with `status_display_type` 1, so the member list reads "Listening to {artist}"
rather than the application's name; `details` is the title, `state` the artist, the album the text of the image,
the timestamps give Discord's progress bar. Nothing is shown while paused or stopped (Discord has no paused state
for this), nor for tracks without tags (`PlayedTrack.hasTags`, as for scrobbling).

The image is the asset `icon` uploaded in the Developer Portal (Rich Presence > Art Assets). Album covers aren't
sent: Discord takes an image only as an asset or an https URL, local files have none, and the cover URLs of a
Subsonic server carry the credentials. Looking covers up elsewhere (Cover Art Archive, iTunes) would be the way if
that is wanted some day.

## Setup

The application ID is not a secret (Discord shows it to anyone who looks at the activity), but it is kept out of
the sources anyway: `ICHM_DISCORD_APP_ID` in `.env`, written XOR-obfuscated (`Obfuscation`) into the bundle's
`Info.plist` as `ICHMDiscordAppID` by `build.sh`. A build without it shows the switch disabled.
