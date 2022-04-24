#myName = "iCanHazMusic"
#myVer = "0.4.0"
#myNameVer = #myName + " " + #myVer
#myUserAgent = #myName + "/" + #myVer
#myID = "wtf.d7.icanhazmusic"
#myURL = "https://github.com/deseven/iCanHazMusic"
#myAbout = ~"written by deseven, 2021\n\nLicense: UNLICENSE\nURL: " + #myURL + 
           ~"\n\n3rd-party components:\n" +
           ~" - FFmpeg (https://ffmpeg.org)"

#geniusToken = "5ssfgWNLZE4ETICJ8EspeGmrVu-Jqp_W0S4q5cJ-Fz_tEKGYimesWxTx9dZ0CO_b"

#lastfmEndpoint = "https://ws.audioscrobbler.com/"
#lastfmAPIKey = "b29cdf01b8e0a255c6a55e68685d6cdf"
#lastfmSecret = "0697a290be37610c1081ccd5f0a0f82a"

#terminalNotifier = "/usr/local/bin/terminal-notifier"

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
  #wndFind
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
  #prefsPanel
  #prefsUseTerminalNotifier
  #prefsUseTerminalNotifierNote
  #prefsUseGenius
  #prefsUseGeniusNote
  #prefsWebEnable
  #prefsWebPort
  #prefsWebPortLabel
  #prefsWebApiKey
  #prefsWebApiKeyLabel
  #prefsWebLink
  #prefsShortcutEdit
  #prefsShortcutToggleLabel
  #prefsShortcutToggle
  #prefsShortcutNextLabel
  #prefsShortcutNext
  #prefsShortcutPreviousLabel
  #prefsShortcutPrevious
  #prefsShortcutFindLabel
  #prefsShortcutFind
  #actionSearch
  #actionResults
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
  #evWebStarted
  #evWebStopped
  #evWebSleep
  #evWebRequest
  #evWebUpdateNowPlaying
  #evWebGetAlbumArt
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
  #playlistMenu
EndEnumeration

Enumeration menuItems
  #openPlaylist
  #savePlaylist
  #addDirectory
  #addFile
  #playlistFind
  #playlistDontGroupByAlbums
  #playlistQueue
  #playlistPlay
  #playlistFinder
  #playlistReloadTags
  #playlistRemove
  #playbackCursorFollowsPlayback
  #playbackPlaybackFollowsCursor
  #playbackOrderDefault
  #playbackOrderShuffleTracks
  #playbackOrderShuffleAlbums
  #playbackStopAtQueueEnd
  #lastfmState
  #lastfmUser
  #dockMenu
  #dockArtist
  #dockTitle
  #dockPlayPause
  #dockNext
  #dockPrevious
  #dockNextAlbum
  #dockPreviousAlbum
  #dockStop
  #actionUp
  #actionDown
  #actionConfirm
  #actionCancel
  #playlistUp
  #playlistDown
  #playlistNext
  #playlistPrevious
EndEnumeration

Enumeration playbackOrder
  #orderDefault
  #orderShuffleTracks
  #orderShuffleAlbums
EndEnumeration

Enumeration albumArt
  #defaultAlbumArt
  #currentAlbumArt
  #tmpImage
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
  dont_group_by_albums.b
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

Structure settingsShortcuts
  toggle_shortcut.s
  next_shortcut.s
  previous_shortcut.s
  find_shortcut.s
EndStructure

Structure settings
  last_played_track_id.i
  use_terminal_notifier.b
  use_genius.b
  shortcuts.settingsShortcuts
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