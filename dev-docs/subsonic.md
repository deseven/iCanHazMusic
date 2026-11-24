# Subsonic notes

A Subsonic server (Subsonic, Navidrome, Airsonic, Gonic, ... anything that speaks API 1.16.1 with JSON answers; tested
against Navidrome) is a source of **playlists of its own**: its playlists have a section in the playlist selector, the
server is the source of truth for them and the app keeps a copy (see "Playlists of a server"). They are never mixed with
the local playlists (`playlists/*.json`): a remote playlist has only tracks of its server, a local one gets no tracks from
a server any more. The playback queue can have tracks of both. Code: `src/Core/Integrations/Subsonic/`, settings in
`Core/Config/SubsonicConnectionConfig.swift`, UI in `UI/Preferences/SubsonicConnection*.swift` (Preferences > Subsonic),
`UI/MainWindow/PlaylistSelector.swift` (the sections) and `UI/Subsonic/` (File > Add from Subsonic...).

## Config

`subsonic` in `config.json` is an array of `{id, name, public_endpoint, local_endpoint, username, password,
send_scrobbles, enabled, cache_size}`, kept sorted by name. `cache_size` (`SubsonicCacheSize`) is a number: GB for a limit
(1-100, 5 by default), 0 for none, -1 for unlimited; anything else reads as the default. **Tracks refer to a connection by `id`** (a UUID made when it is added),
never by name: the name is a label, renaming a connection changes nothing but the config. At least one endpoint is
required; endpoints are normalized (http/https, no trailing slash, a pasted trailing `/rest` is cut). The password is
obfuscated like the scrobbling secrets (`Obfuscation`): token authentication needs the password itself, so it can't be
kept hashed.

## The API

`SubsonicAPI` (pure): URLs `{endpoint}/rest/{method}.view?u=&t=md5(password+salt)&s=salt&v=1.16.1&c=iCanHazMusic&f=json`,
a new salt for every request. Used: `ping`, `getArtists`, `getArtist`, `getAlbum`, `getPlaylists`, `getPlaylist`,
`createPlaylist`, `updatePlaylist`, `deletePlaylist`, `getCoverArt`, `download`, `scrobble`
(the ID3 endpoints, not the folder based ones; Navidrome only has those). What changes something (the three playlist
writers, `SubsonicConnection.write`) is a **POST** with the parameters, credentials included, in the form body (a playlist
of thousands of songs doesn't fit in a URL, and the URL stays free of credentials); a server that answers 405/501 gets a
GET instead. A call that is repeated on the other endpoint after a lost answer can be done twice (`createPlaylist` then
makes two playlists): accepted. IDs and counts are read as strings or numbers,
a single object counts as a list of one: servers differ. **The URLs carry the credentials: never log one** (the log says
`SubsonicAPI.redacted(url)` or the song ID; `PlaybackSource.logPath` is the URL without them).

Errors (`SubsonicError.Kind`): `.connection` (unreachable, 5xx, an answer that isn't Subsonic's: worth trying the other
endpoint), `.authentication` (codes 40-44, 50, HTTP 401/403), `.notFound` (70), `.rejected`. Only the first two show on
the connection's status; a song that is gone isn't a problem of the connection.

## Endpoints: local and public

`SubsonicConnection` decides where calls go. One endpoint: that one. Both: the local one is preferred. A `ping` (6 s
timeout, the local address may not exist where the user is) is made at start, every minute and when the network changes
(`SubsonicService` watches `NWPathMonitor`); it answering means local, not answering means public (which is then
pinged too, so the status says whether the server can be reached at all). A call to an address that can't be reached is
repeated on the other one at once, and the connection stays with whichever worked (`noteResult` is the same for what
the downloads learn). One failed ping is enough to give up the local address: the public one costs nothing but speed.
Status (`SubsonicService.status(of:)`, runtime only): time of the last interaction (a ping or a call) and whether it went
through; the tooltip says which address.

## Tracks in playlists

Like a CUE track, a Subsonic track has a pseudo path and an object in the playlist file (`TrackEntry.subsonic`; the cached
copy of a remote playlist is a `PlaylistFile` like any other):

```json
{"id": 7, "path": "subsonic/0f6c3a3e-52e8-4f1b-9c9c-6a1e3b8d7a11:song-id", "title": "...", "codec": "FLAC",
 "subsonic": {"album_id": "...", "cover_art": "...", "suffix": "flac"}}
```

The path alone is enough to read the entry (a UUID has no colon, the song ID is whatever the server uses); the object
is the grouping by album, the cover and the suffix. `SubsonicRef` is the model (`Track.subsonic`). What the engine plays
(`Track.url`, `PlaybackSource.url`) is `subsonic://{connection id}/{song id}?ext=flac`, an URL that is **not a file**:
anything that opens `url` as a file has to check (`url.subsonicRef`, `Track.canReveal`). `Album.directory` is
`subsonic://{connection id}/album/{album id}` (`AlbumKey` uses the URL for such albums), which is what groups the tracks
of one server album. Tags come from the API when the tracks are read (`SubsonicImport`) and again whenever the playlist is
read from the server (Reload Tag(s) does that at once, see "Covers"), and playlist export (M3U/PLS) skips them (and is off for remote playlists). The codec label starts as the upper-cased suffix and becomes
what `CodecLabel` makes of the file after the first play, like everywhere.

A connection that is switched off hides its playlists (they leave memory, playback from them stops, their queued tracks
go; the cache stays); one that is removed has its whole directory deleted. A track in the queue whose connection is later
switched off fails to play with the reason; the usual skip (and the give-up after 10 failures in a row) applies.

## Playing: `SubsonicDownloads`

The backend works with files (`PCMSource`), so a song is downloaded whole with `download` (the original file, nothing
transcoded) into `.cache/subsonic/{connection id}/downloads/{hash of the song id}.{suffix}` (made from a `{...}.{random}.part`
next to it, renamed under the lock when complete and only if somebody still wants it) and played like a local file;
everything the playback learned about files (exact lengths, seeking, WavPack/APE) applies as it is. The name is the same
every time, so a file that is there is the song, complete (the partial files a crash left are deleted when
`SubsonicDownloads` is made).

- **Leases.** `acquire(url)` starts the download if it isn't under way and returns a `SourceLease`; holders of a lease for
  the same song share one file; **when the last lease goes away the download is cancelled** (a file that is there goes
  or stays by the cache size, below). Holders: the decoder of a track (`TrackDecoder`, for as long as it exists or until
  `cancel()`), the engine for the next track (`prefetch`), the waveform while it measures, an automatic download of a
  playlist (below) while that song is downloaded. Nothing else keeps a file (but pinning, below).
- **Order matters in the engine.** A restart (seek, a changed next track, a device change) makes the new slot, which
  acquires the lease, *before* the old slots are cancelled, so the file isn't deleted and downloaded again; a parked
  (long paused) track keeps its lease in `Parked`.
- **Prefetch.** The decoder of the next track is made only when the current one is almost decoded (`lookahead`, 5 s), far
  too late for a download. So `PlaybackEngine.updatePrefetch` takes the lease on the next track when the current one has
  `prefetchLead` (60 s) left (at once for a shorter track), and lets go of it when the next track changes.
- **Timeouts.** The decoder's 10 s timeout is about a file that doesn't answer; the wait for the download comes before it
  and has none of its own (`fetchIfNeeded`). The download has its own limits: 30 s without a byte is a failure
  (`SubsonicTransfer`), a download that keeps going isn't limited. `cancel()` ends the wait at once.
- **Failures.** A download that fails is forgotten at once (the waiters get the error), the next `acquire` tries again. A
  `.connection` error is tried on the other endpoint; the server answering with an error instead of a file (a 200 with
  a JSON body) is read as that error, never saved as audio.
- Memory: files are streamed to disk, never held whole. Disk: see the cache.

### The cache

`.cache/subsonic/{connection id}/` has three directories: `downloads/` (below), `playlists/` (the cached playlists, see
further down) and `covers/` (the covers of played albums, see "Covers" below), and `pinned.json` (below) if anything is pinned. `SubsonicDownloads` only ever deletes inside `downloads/`,
except for a removed connection, which loses the whole directory. The connection's `cache_size` says what happens to the downloaded files nothing needs any more. `SubsonicService` hands the sizes of
*all* connections (disabled ones too) to `SubsonicDownloads` (`setCachePolicies`, whenever the list is saved); a
connection that isn't in them is a removed one, and one that is unknown to the downloads (tests) has no cache.

- **None.** As it always was: a file is deleted the moment its last lease goes (under the lock, so that an `acquire`
  right after can't have it taken away), `downloads/` at launch and quit (the cached playlists stay: they aren't downloads).
- **A size.** The file stays. It is *touched* (modification time = now) by every `acquire` that finds it and by the
  end of its last lease, so the time says when it was last used. A file that comes by a new download is followed by
  `trim`: when the files of the connection are over the size, the oldest are deleted until it fits again, **never one
  that is leased** (the size can be exceeded while files are in use; the trimming happens before the waiters of the
  new file are told, so the file is leased by then). The same is done at launch.
- **Unlimited.** Nothing is ever deleted.
- **Removed connection.** `removeCache(of:)`: its downloads are cancelled and its directory deleted (found by
  `reconcile()`, which runs at launch and whenever the sizes change). Disabling is not removing: the files stay, and
  songs that are in them still play (nothing is downloaded for a switched off connection).
- **Changing the size** runs `reconcile()` too: to none deletes what nothing holds, to a smaller size trims.
- **Gone playlists.** `removeFiles(ofSongs:)`: when a playlist is deleted (here or on the server) the downloaded files of its
  songs that no other playlist of the connection has are deleted, unless something holds them (`SubsonicPlaylists`
  decides which songs).
- **Pinned files** (`setPinnedSongs`, by `SubsonicAutoDownloads`, see "Playlists downloaded automatically") are outside of
  all of the above: never deleted (not on release, trim, reconcile, quit, nor by `removeFiles(ofSongs:)`) and **not counted
  towards the size**. The list (file names) is saved in `{connection id}/pinned.json` and read when `SubsonicDownloads` is
  made, so it holds before anything else is known at launch, and for a switched off connection. A file that loses its pin
  is an ordinary cached file from then on: `reconcile(connection)` runs at once (none: deleted; a size: trimmed;
  unlimited: stays).
- `cleanUpAtQuit()` (sync, the app is going away): `downloads/` of connections without a cache (but the pinned files) and
  everything of those that are gone are deleted, the others lose only partial files. *Two instances on one `--workdir` would delete each other's files:* the
  app doesn't prevent that, and they already share `config.json` and the playlists.

### Covers

Nothing is fetched when tracks are added or a playlist is opened: a cover is asked for only when something shows it, **once
per album and run** (`SubsonicCovers`, which does it all; `SubsonicService.cover` is the call to the server). It makes two
things:

1. The picture, asked for at 1200 px (`SubsonicCovers.originalSize`, which counts as "the original"), kept by `SubsonicCoverCache`
   in `{connection id}/covers/`, one file per album, named by a hash of the album's ID and one of the cover id and size. Albums
   are told apart by `SubsonicRef.albumID` (the cover id for a song that has none); the cover id says which picture it is, since
   servers put a version into it (Navidrome adds the time of the last change). This is what Now Playing shows.
2. The thumbnail of the playlist's album block, made from it (`Thumbnailer`) and put into the cover cache (`covers.sqlite`)
   under `Album.key` if it is missing, or if the picture just came from the server.

Who asks:
- **Now Playing**, when an album starts (`PlaybackArtwork.Lookup.remote` -> `SubsonicCovers.original`), only while it shows
  art. With Now Playing art hidden, `PlaybackState` still makes the thumbnail if the playlist is grouped by albums and its header
  style shows art (nothing at all if neither does).
- **An album block on screen** (`AlbumCover` -> `CoverCache.fetchMissingThumbnail` -> `SubsonicCovers.ensureThumbnail`): only
  once the header stayed on screen (a fast scroll cancels its task before), only in a playlist grouped by albums (a flat one has
  no blocks), only with a header style with art. The block shows the placeholder meanwhile and swaps the thumbnail in.
- **Reload Tag(s)** (below).

Rules:
- A file for the very cover id asked for is used without asking the server (that also works offline and for a switched off
  connection). Otherwise the server is asked; its answer, if it is an image, replaces what the album had. If it doesn't answer, a
  file of the album with another cover id (a stale one) is used, better than none.
- A thumbnail that is in the cover cache is enough for an album block: nothing is asked, even offline. So a cover that changed
  on the server shows in the playlist only after the next play of the album (the cover id differs from the file's: fetched, thumbnail
  replaced) or Reload Tag(s).
- An album that was dealt with this run (it has a thumbnail, or the server couldn't give the cover) isn't asked for again by album
  blocks (in memory, `settled`); a play does try again.
- The work in flight is shared per album (a block and a play never fetch twice) and goes on if the block that started it scrolls away;
  `SubsonicCovers.onThumbnailStored` makes the views forget the album's old cover (`CoverCache.forget`).
- **Never pruned, and not subject to the connection's cache size** (that is about songs; covers are a few hundred KB and
  offline use is the point). They go with the connection's directory when the connection is removed.
- Only the embedded art of the song's file is *not* looked at for Subsonic albums: the server is the only source.

### Reload Tag(s)

Works in playlists of a server too (`PlaylistItemActions.reloadTags` -> `SubsonicPlaylists.reloadTags`), without a sheet:
the playlist is read from the server again (`refreshContent`: titles, albums, years, cover ids; skipped while a change of ours
waits to be sent), then the covers of the albums of the selection are asked for again whatever is on disk
(`SubsonicCovers.reload`, four at a time) and their thumbnails made anew. If the playing album is one of them, Now Playing loads
its art again (`PlaybackState.albumCoversWereReloaded`). A cover the server can't give leaves what there is.

## Playlists of a server

`PlaylistStore` holds them next to the local ones: a playlist is a `PlaylistID` (`.local(name)` or `.remote(connection,
server id)`, saved as `subsonic:{connection}/{id}` in `config.json`'s `active_playlist` and the playback state), so two
playlists can have the same name and a rename changes nothing about a playlist's identity. The queue, search and playback
refer to playlists by it. `RemoteSection` is what the selector shows per enabled connection.

**Cache** (`.cache/subsonic/{connection id}/playlists/`): `index.json` (`RemotePlaylistIndex`: per playlist what the last
`getPlaylists` said: `name`, `owner`, `changed`, `song_count`, whether it is somebody else's or read-only, and `synced`, the
`changed` of the version the content is; also `auto_download`, the app's own) and one `PlaylistFile` per playlist (named by a hash of its ID; it also keeps
`is_flat` and `last_played` of the playlist, which are the app's own). The playlists of the enabled connections are read
from it at launch, so they are there and play (from downloaded files) before the server answers or when it doesn't.

**`SubsonicPlaylists`** keeps the store and the servers in step (`start()` at launch):

- *Looking*: at launch, every minute, when the network changes, when a connection is switched on and when a playlist is
  opened. One `getPlaylists` per connection; only playlists whose `changed` differs from `synced` are read with
  `getPlaylist` (a server that doesn't date them is compared by song count). New ones appear (flat: remote playlists open
  with "Don't group by albums" on), gone ones are deleted like a deleted local one, plus their cached file and the downloaded
  files of songs no other playlist of the connection has. A listing that was asked for before a create/rename/delete of ours
  is thrown away (it can't know of it).
- *Merging* (`RemotePlaylistMerge`): what the server says is the content; the tracks keep their `TrackID` (the k-th copy of a
  song takes the ID of the k-th copy before), the durations/format labels playback learned, and the grouping of the playlist.
  The queue, the playing track and `last_played` survive a refresh this way.
- *Changing*: removing tracks, moving them and turning grouping on show at once and are sent in the background, one at a
  time per playlist, as **the whole order as shown** (`createPlaylist` with the ID replaces the songs; `songIndexToRemove`
  would trust our idea of the positions, so it isn't used; an empty list is `updatePlaylist` removing every index). Before
  sending, the server's `changed` must still be the one the edit was made from (`synced`): if somebody else changed the
  playlist meanwhile the edit is dropped, the user is told (`onProblem`) and the playlist shows the server's version. A
  failed write is reported and the playlist is read again. Adding songs (`updatePlaylist songIdToAdd`), creating (private,
  as the server makes them), renaming and deleting wait for the server first; the app doesn't quit before what is on its way
  is sent (`flushEdits`, 5 s at most).
- *Grouped playlists*: a playlist shown grouped by albums is kept in that order on the server as well: turning grouping on
  (the user confirms: it can reorder the tracks) and any refresh after which the grouped order differs from the server's send
  the grouped order, once (`rewrites`: if the server doesn't keep it, it isn't tried again for the same result). Never for a
  playlist that can't be changed, and grouping is refused for an own playlist while it can't be changed (it would be
  reordered later without asking).
- *Read-only* (`canEdit`, `readOnlyReason`): somebody else's playlists (`owner` is not the connection's user), those the
  server marks `readonly` (OpenSubsonic), any while the last call to the server failed (the reason is the error), and one
  that was never read. They play but nothing changes: the menu items, the context menu entries and the drag are off, the
  playlist shows a lock and a "Read-only: reason" line above it, the section header a "can't be reached" mark.

- *Watching* (`watcher`, `RemotePlaylistWatching`: `SubsonicAutoDownloads`) is told when connections change, after every
  look at a server, when content was replaced or edited, and when playlists are gone, **before** the files of gone
  playlists are deleted (so their pins are let go of first).

UI: with a connection enabled the selector has "Local Playlists" and one section per connection, each with its own + (off
while the server can't be reached); File > Add Directory/File(s) and drops are for the local playlist being shown, Add from
Subsonic for the remote one; Import/Export playlist are off for remote playlists. Window title: "Name • Connection".

## Playlists downloaded automatically

The context menu of a remote playlist in the selector has "Download All Tracks Automatically" (a checkmark item; turning
it on asks first, `PlaylistActions.setAutoDownload`: the files take disk space the cache size doesn't limit). The flag is
`RemotePlaylistInfo.autoDownload` (`auto_download` in `index.json`, kept over refreshes by `setRemotePlaylists`), so it goes
with the playlist and with a removed connection. `SubsonicAutoDownloads` does the rest, per connection
(`playlistsChanged(of:)`):

- The songs of all flagged playlists of the connection (each once) are read from the store and made the **pinned files**
  (`SubsonicDownloads.setPinnedSongs`, see the cache). A song that leaves them (flag off, removed from the playlist, the
  playlist gone) gets the cache size right away. A connection that is switched off is never looked at, so its pins stay.
- Which of them are on disk is looked at off the main thread; the missing ones are downloaded in playlist order, two at a
  time, through `acquire` like playback (a song that plays meanwhile shares the download; the lease goes once the file is
  there, the pin keeps it). A song that fails is tried again with the next look (after every refresh, once a minute); three
  failures in a row stop the run until then (the server is probably unreachable). A look that finds nothing changed and
  nothing missing does nothing.
- `progress` (per flagged playlist: songs there / songs, each counted once) and `downloading` (connections with a run) are
  observed by the selector: a small bar until the playlist is complete, nothing after that (`AutoDownloadMark`, a view of
  its own so a finished download redraws only it), the tooltip says whether it is downloading or waiting for the server.

## Adding tracks

File > Add from Subsonic... (only while the playlist shown is one of a server that can be changed) opens a sheet on the main
window for the connection of that playlist: artist (with a filter), album ("All albums" or one), the tracks below with
checkboxes, all ticked. Picking an artist loads all its albums with their songs (`albumContents`: one `getArtist` and one
`getAlbum` per album, four at a time); an album afterwards is a filter. `SubsonicBrowseModel` is the logic. Songs are ordered
by disc, then track number; the disc number isn't kept.

Adding (`ImportCoordinator.addSubsonic`, one at a time with the other imports) goes behind the same kind of progress
sheet as adding files (`SubsonicImportSession`, `SubsonicImportProgressView`, Abort works): the albums are made, then the
songs are added to the playlist on the server (`SubsonicPlaylists.append`). **An aborted run adds nothing.**
Nothing is downloaded here: songs are downloaded when they play (and are then subject to the cache size), or right away
if the playlist is downloaded automatically; covers are fetched when something shows them (see "Covers").

## Scrobbling

With "Send scrobbles" on, `SubsonicScrobbler` (a `PlaybackListener`) sends `scrobble?id=&time=&submission=true` to the
song's own server when a track was listened to enough (`ScrobbleRule`), through a `ScrobbleQueue` per connection (retries
as in `scrobbling.md`). The server counts a play and forwards it to whatever it is set up for. No "now playing"; tracks
without tags are sent too (a song is told by its ID); files of this Mac and songs of other connections never are.

## Not done

- Progressive playback (start before the download is complete), `stream` (transcoding), folder based browsing, search on
  the server, `getLyrics`, API key authentication, self-signed certificates.
- Editing a remote playlist while its server can't be reached (it would need a queue of changes and a way to settle
  conflicts: the playlists are read-only then), choosing "public" when making a playlist (the server's default, private),
  moving a track in a playlist other than by drag and drop.
