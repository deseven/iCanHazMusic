#myName = "iCanHazMusic"
#myVer = "0.2.0"
#myNameVer = #myName + " " + #myVer
#myUserAgent = #myName + "/" + #myVer
#myURL = "https://github.com/deseven/iCanHazMusic"
#myAbout = ~"written by deseven, 2021\n\nLicense: UNLICENSE\nURL: " + #myURL + 
           ~"\n\n3rd-party components:\n" +
           ~" - FFmpeg (https://ffmpeg.org)\n" +
           ~" - Hiawatha (https://www.hiawatha-webserver.org)"

#geniusToken = "5ssfgWNLZE4ETICJ8EspeGmrVu-Jqp_W0S4q5cJ-Fz_tEKGYimesWxTx9dZ0CO_b"

#lastfmEndpoint = "https://ws.audioscrobbler.com/"
#lastfmAPIKey = "b29cdf01b8e0a255c6a55e68685d6cdf"
#lastfmSecret = "0697a290be37610c1081ccd5f0a0f82a"

#alphaWarning = "This is a very early version of " + #myName + 
                ~", it may contain bugs and... Who am I kidding, it does indeed contain bugs!\n\n" + 
                "Please share your feedback by creating an issue on GitHub (https://github.com/deseven/iCanHazMusic/issues) or by contacting me directly (https://d7.wtf/contact)." +
                ~"\n\n" +
                ~"What should work: \n" +
                ~" - m4a, aac, mp3, wav, ogg, flac and aiff playback\n" +
                ~" - last.fm scrobbling and now playing updates (enable it in the menu)\n" +
                ~" - playback navigation and queue\n" +
                ~" - grouping by albums\n" +
                ~" - dock menu\n" +
                ~" - big (10k+ entries) playlists\n" +
                ~" - window size and position saving\n" +
                ~" - album art from external files\n" +
                ~" - lyrics loading from Genius (if you installed the lyricsgenius module, see the readme in the repo)\n" +
                ~" - queue, playback orders\n" +
                ~"\n" +
                ~"What should work in the future: \n" +
                ~" - global hotkeys for playback\n" +
                ~" - album art from tags\n" +
                ~" - playlist entries rearrangement\n" +
                ~" - seekbar\n" +
                ~" - volume control\n" +
                ~" - drag'n'drop operations\n" +
                ~"\n" +
                ~"What is not planned: \n" +
                ~" - gapless playback (well, maybe someday...)\n" +
                ~" - CUE support\n" +
                ~" - equalizer\n" +
                ~" - tags editing\n" +
                ~" - advanced foobar2000-level customization (i'm too dumb for that, sorry)\n"

#playSymbol = "▶"
#pauseSymbol = "❚ ❚"
#nextSymbol = "▶▶"
#previousSymbol = "◀◀"
#nextAlbumSymbol = "▶❚"
#previousAlbumSymbol = "❚◀"
#stopSymbol = "■"
#refreshSymbol = "♻"
#processingSymbol = "◔"
#albumSymbol = "⭘"

#defaultTimeout = 900

Enumeration
  #wnd
  #wndPrefs
  #wndAction
  #playlist
  #albumArt
  #nowPlaying
  #nowPlayingProgress
  #nowPlayingDuration
  #lyrics
  #toolbarPlayPause
  #toolbarNext
  #toolbarPrevious
  #toolbarNextAlbum
  #toolbarPreviousAlbum
  #toolbarStop
  #toolbarLyricsEdit
  #toolbarLyricsReload
  #toolbarLyricsReloadWeb
EndEnumeration

Enumeration globalEvents #PB_Event_FirstCustomValue
  #evTagGetSuccess
  #evTagGetFail
  #evTagGetFinish
  #evTagGetSaveState
  #evPlayStart
  #evPlayFinish
  #evLyricsFail
  #evLyricsSuccessGenius
  #evLyricsSuccessFile
  #evUpdateNowPlaying
  #evNowPlayingRequestFinished
  #evScrobbleRequestFinished
  #evFCGIFailed
  #evFCGIStarted
  #evFCGIStopped
  #evFCGIUpdateNowPlaying
  #evFCGIGetAlbumArt
  #evHiawathaStarted
  #evHiawathaFailedToStart
  #evHiawathaDied
  #evHiawathaStopped
EndEnumeration

Enumeration columns
  #status
  #file
  #track
  #artist
  #title
  #duration
  #album
  #details
EndEnumeration

Enumeration menu
  #menu
  #openPlaylist
  #savePlaylist
  #addDirectory
  #addFile
  #playbackCursorFollowsPlayback
  #playbackPlaybackFollowsCursor
  #playbackOrderDefault
  #playbackOrderShuffleTracks
  #playbackOrderShuffleAlbums
  #playbackStopAtQueueEnd
  #lastfmState
  #lastfmUser
  #playlistMenu
  #playlistQueue
  #playlistPlay
  #playlistReloadTags
  #playlistRemove
  #dockMenu
  #dockArtist
  #dockTitle
  #dockPlayPause
  #dockNext
  #dockPrevious
  #dockNextAlbum
  #dockPreviousAlbum
  #dockStop
EndEnumeration

Enumeration playbackOrder
  #orderDefault
  #orderShuffleTracks
  #orderShuffleAlbums
EndEnumeration

Enumeration albumArt
  #defaultAlbumArt
  #currentAlbumArt
EndEnumeration

Enumeration lastfmAuthSteps
  #getToken
  #openAuthLink
  #getSession
EndEnumeration

Structure ffprobe_format
  format_name.s
  duration.s
  bit_rate.s
  Map tags.s()
EndStructure

Structure ffprobe_stream
  Map tags.s()
EndStructure

Structure ffprobe_answer
  format.ffprobe_format
  List streams.ffprobe_stream()
EndStructure

Structure tags
  artist.s
  track.s
  album.s
  title.s
EndStructure

Structure track_info
  id.i
  path.s
  format.s
  duration.s
  bitrate.i
  tags.tags
EndStructure

Structure nowPlaying
  ID.i
  path.s
  artist.s
  title.s
  album.s
  duration.s
  durationSec.i
  currentTime.i
  details.s
  lyrics.s
  albumArt.s
  isPaused.b
EndStructure

Structure settingsLastfm
  session.s
  user.s
EndStructure

Structure settingsWindow
  x.i
  y.i
  width.i
  height.i
  fullscreen.b
EndStructure

Structure settingsPlaylist
  status_width.i
  track_width.i
  artist_width.i
  title_width.i
  duration_width.i
  album_width.i
  details_width.i
EndStructure

Structure settingsPlayback
  cursor_follows_playback.b
  playback_follows_cursor.b
  stop_at_queue_end.b
  playback_order.s
EndStructure

Structure settingsWeb
  use_web_server.b
  web_server_port.l
  api_key.s
EndStructure

Structure settings
  last_played_track_id.i
  alpha_alert_shown_for.s
  web.settingsWeb
  lastfm.settingsLastfm
  window.settingsWindow
  playlist.settingsPlaylist
  playback.settingsPlayback
EndStructure

#sep = Chr(10)

#justifyLeft = 0
#justifyRight = 1
#justifyCenter = 2