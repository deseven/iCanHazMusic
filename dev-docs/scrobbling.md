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
  (`ScrobbleRule`). Tracks without an artist or a title are never reported; what is reported is the playlist **data**
  (`PlayedTrack`), never what the UI shows for a missing value ("Unknown Artist", the file's name as a title, see
  `TagFallback`). The album is optional, see below.
- **Retry-After**: when a server asks to wait (`Retry-After`, seconds or an HTTP date; LRCLIB documents it, MetaBrainz
  doesn't, so it is honored as a general courtesy; for a 429 or 503 without it MetaBrainz's own `X-RateLimit-Reset-In`,
  which their docs tell clients to use), `URLSessionTransport` puts it into `HTTPAnswer.retryAfter`, the clients into
  `ScrobbleError.retryAfter` (temporary errors only), and the queue waits that long **instead of** its backoff, at most
  2 minutes (`RetryDelay`, shared with `LRCLIBQueue`; the tries are still counted, so 10 at most). If the server asked
  for more, we try again sooner than it said. Without it the backoff above applies.
- **Outdated now playing calls are not sent or repeated** (`Call.isSuperseded(by:)`). A now playing update or a
  clearing is outdated when a later update or clearing is queued (the track was switched, playback stopped), an update
  also when its own track was scrobbled (it was left). Waiting ones are removed when the newer call is added; the one
  being tried can't be (it may be on its way), so when it has to be repeated it is dropped instead: at once, or, if the
  server asked to wait, after that wait (the pause belongs to the service, the next call must keep it too).
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
  sent when the tags have one, the MusicBrainz ID never (we don't have it). The spec wants every field present and
  empty if not known, so a track without an album has `b=` / `b[0]=` (never "Unknown Album").

## ListenBrainz details

- `GET {endpoint}/1/validate-token` (the answer is 200 with `valid` true or false) and `POST {endpoint}/1/submit-listens`
  with `listen_type` `playing_now` or `single`, both with `Authorization: Token ...`. `additional_info` names the app and
  has the duration and the track number. `release_name` is optional there and left out for a track without an album.
- 401 is an authentication error, 400 a refused request, 429 and 5xx are temporary.
- MetaBrainz requires a way to contact the author in the `User-Agent` (`Name/version (contact-url)`, requests without
  it may be blocked). `URLRequest(appURL:)` adds `AppConstants.contactURL` for MetaBrainz
  hosts only: `*brainz.org` (api.listenbrainz.org, musicbrainz.org, ...; `AppConstants.isMetaBrainzHost`). A
  self-hosted server gets the plain `iCanHazMusic/{version}`. Any future MetaBrainz request (MusicBrainz lookups)
  only has to be built with `URLRequest(appURL:)`.
- Rate limit (their docs: never more than one call per second, the `X-RateLimit-*` headers tell the rest, a 429 is
  the answer to too many): `URLSessionTransport` spaces out all requests to MetaBrainz hosts, 1.1 s between the starts
  of two (`RequestSpacer.metaBrainz`, shared by every queue and the connection test, since the limit is per client). It
  is in the transport so that nothing can forget it; the scrobble, the clear and the next now playing at a track
  change are what it is for. A 429 or 503 is waited out as described under "Retry-After" below.
- Not done (yet): no MBIDs are submitted (the tags aren't read for them), `tracknumber` is sent as a number while the
  docs say string. `X-RateLimit-Limit/Remaining` are not read.
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
(shown once the main window is on screen, `MainWindowOpener.waitUntilShown()`, after the migration's own question, so a login from the old
version is covered) explains what happened and offers two buttons. The migration's question has to be asked before
SwiftUI has launched (it decides what the config is), and a modal alert run that early keeps SwiftUI from opening the
main window; `AppDelegate` then asks for it the way a Dock click does (a reopen event sent through LaunchServices,
`openMainWindowAfterEarlyAlert`). So the notice can't be run from `App.init()` either, and waits for the window:

- **Set Up Now** puts `LegacyLastFM.suggestedService` (name "Last.fm", Last.fm's endpoint, the account name if it is
  known, no password) into `ScrobblingSetupRequest`, which opens the Preferences window as soon as it has the open action (`MainWindow`
  registers it; the request may come first or second), then `PreferencesView` switches to the Scrobbling tab and `ScrobbleServiceList` opens the add sheet with the service.
  The sheet focuses the password field; saving needs it, as the old session key can't be turned into one
  (Audioscrobbler needs the password, which we never had).
- **Set Up Later** does nothing; the same service is added by hand in Preferences > Scrobbling.
