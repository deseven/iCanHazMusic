# Scrobbling notes

Last.fm made its API keys paid (from 1 December 2026), so the app has no Last.fm integration (and can't hold an API
key it could protect). Scrobbling is generic instead: any number of user-configured services, each speaking one of

- **Audioscrobbler 1.2.1**, the legacy "Submissions Protocol": Last.fm (`https://post.audioscrobbler.com`) still
  accepts it, so do Libre.fm (`https://turtle.libre.fm`) and many self-hosted servers;
- **ListenBrainz** (`https://api.listenbrainz.org`, or a compatible server).

Code: `src/Core/Integrations/Scrobbling/`, settings of one service in `Core/Config/ScrobbleServiceConfig.swift`, UI in
`UI/Preferences/ScrobbleService*.swift` (Preferences > Scrobbling).

## Config

`scrobbling` in `config.json` is an array of `{id, name, type, endpoint, username, secret, submit_now_playing,
enabled}`, kept sorted by name (`AppConfig.validated()` and `ScrobblingService` do it). `type` is `audioscrobbler` or
`listenbrainz`; an entry without a known type is dropped when reading, every other wrong value falls back to a default.
Endpoints are normalized (http/https, no trailing slash, no query) when saved. `secret` (the password, or the
ListenBrainz user token) is obfuscated with `Obfuscation` (XOR with a key from the sources, base64): not protection,
only unreadable in a backup or a screenshot.

## Flow

- `ScrobblingService` is a `PlaybackListener`. At start it authenticates every enabled service; adding, editing
  (connection details) or switching one on does the same.
- Each service has its own `ScrobbleQueue` (one call at a time, in order, in the background). Retries as before:
  temporary failures wait 1, 2, 4, ... s, up to 10 tries, then the call is dropped; a call the server refuses for itself
  is dropped; refused credentials drop everything pending for that service. A failed call never stops the queue from
  taking the next one, so **every new track is a new try**: a service that was offline at start, or whose password
  was fixed elsewhere, is picked up again without user action.
- What the user sees (`ScrobblingService.status(of:)`, runtime only): the time of the last scrobble that went through
  and an error mark if the last try (authentication, now playing or scrobble) failed. Any call that goes through
  clears the mark.
- A track is announced as now playing when its audio starts (if the service has "submit now playing" on) and scrobbled
  when it is left, after half of its length or 4 minutes, whichever comes first, if it is longer than 30 s
  (`ScrobbleRule`). Tracks without tags are never reported.
- Every request has a 60 s limit (`ScrobbleHTTP.requestTimeout`: the idle timeout and the one for the whole transfer); a request that hits it counts as a temporary failure and is retried.
- Testing a connection in the sheet (`ScrobblingService.test`) uses a throwaway client with the values in the sheet and
  touches neither the saved settings nor the running queues.

## Audioscrobbler details

- Handshake `GET {endpoint}/?hs=true&p=1.2.1&c=ich&v={version}&u={user}&t={ts}&a={md5(md5(password)+ts)}`; the answer is
  `OK`, session ID, now playing URL, submission URL. The username may be empty (some servers don't need it). The
  client ID `ich` is not registered: Last.fm doesn't issue new ones for this protocol, the others take anything.
- `AudioscrobblerClient` (an actor) keeps the session. `BADSESSION` means one new handshake and the same call again;
  three failures in a row drop the session; `BADAUTH`, `BANNED` and `BADTIME` are authentication errors (not retried),
  `FAILED` and everything unexpected is temporary.
- Now playing carries `s,a,t,b,l,n,m`, a submission one track at index 0 (`a[0]...m[0]`, source `P`). The track number is
  sent when the tags have one, the MusicBrainz ID never (we don't have it).

## ListenBrainz details

- `GET {endpoint}/1/validate-token` (the answer is 200 with `valid` true or false) and `POST {endpoint}/1/submit-listens`
  with `listen_type` `playing_now` or `single`, both with `Authorization: Token ...`. `additional_info` names the app and
  has the duration and the track number.
- 401 is an authentication error, 400 a refused request, 429 and 5xx are temporary.
- When playback stops, `POST {endpoint}/1/playing-now/delete` (empty JSON body, so it clears unconditionally) removes
  the now playing status: some servers don't do it on their own, and it would otherwise stay until the duration of
  the last track has passed. `PlaybackState.halt()` tells the listeners (`playbackDidStop()`) when a track that was
  announced is playing, i.e. for the user's stop, the end of the playlist or the queue, a failed output. Not at quit
  (the track is picked up at the next launch). It goes after the scrobble of that track in the same queue, replaces
  a now playing update that is still waiting (and is replaced by a newer update), and is only sent to ListenBrainz
  services with "submit now playing" on. A 404 answer counts as success. Audioscrobbler has no such call.

## Legacy Last.fm data

Loading a config that has `integrations.lastfm.session` (or, for the previous, PureBasic version, `lastfm.session` in its
`settings.json`) keeps the account name in `ConfigStore` (`takeLegacyLastFMNotice()` returns a `LegacyLastFM.Login`);
the login itself is gone from the file right after loading, since the config has no place for it. `LastFMRemovalNotice`
(shown at launch after the migration's own question, so a login from the old version is covered) explains what
happened and offers two buttons:

- **Set Up Now** puts `LegacyLastFM.suggestedService` (name "Last.fm", Last.fm's endpoint, the account name if it is
  known, no password) into `ScrobblingSetupRequest`. No window exists yet at that point, so the request waits:
  `AppDelegate` calls `openPreferencesIfRequested()` after launch (the open action is registered by `MainWindow`),
  `PreferencesView` switches to the Scrobbling tab and `ScrobbleServiceList` opens the add sheet with the service.
  The sheet focuses the password field; saving needs it, as the old session key can't be turned into one
  (Audioscrobbler needs the password, which we never had).
- **Set Up Later** does nothing; the same service is added by hand in Preferences > Scrobbling.
