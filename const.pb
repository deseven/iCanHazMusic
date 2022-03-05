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
  #playlistQueue
  #playlistPlay
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
  use_terminal_notifier.b
  use_genius.b
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

Dim keys.s($FF)
keys($00) = "A"
keys($01) = "S"
keys($02) = "D"
keys($03) = "F"
keys($04) = "H"
keys($05) = "G"
keys($06) = "Z"
keys($07) = "X"
keys($08) = "C"
keys($09) = "V"
keys($0B) = "B"
keys($0C) = "Q"
keys($0D) = "W"
keys($0E) = "E"
keys($0F) = "R"
keys($10) = "Y"
keys($11) = "T"
keys($12) = "1"
keys($13) = "2"
keys($14) = "3"
keys($15) = "4"
keys($16) = "6"
keys($17) = "5"
keys($18) = "="
keys($19) = "9"
keys($1A) = "7"
keys($1B) = "-"
keys($1C) = "8"
keys($1D) = "0"
keys($1E) = "]"
keys($1F) = "O"
keys($20) = "U"
keys($21) = "["
keys($22) = "I"
keys($23) = "P"
keys($25) = "L"
keys($26) = "J"
keys($27) = "'"
keys($28) = "K"
keys($29) = ";"
keys($2A) = ""
keys($2B) = ","
keys($2C) = "/"
keys($2D) = "N"
keys($2E) = "M"
keys($2F) = "."
keys($32) = "`"
keys($24) = "↩"
keys($30) = "Tab"
keys($31) = "Space"
keys($35) = "⎋"
keys($39) = "CAPS"
keys($7A) = "F1"
keys($78) = "F2"
keys($63) = "F3"
keys($76) = "F4"
keys($60) = "F5"
keys($61) = "F6"
keys($62) = "F7"
keys($64) = "F8"
keys($65) = "F9"
keys($6D) = "F10"
keys($67) = "F11"
keys($6F) = "F12"
keys($69) = "F13"
keys($6B) = "F14"
keys($71) = "F15"
keys($6A) = "F16"
keys($40) = "F17"
keys($4F) = "F18"
keys($50) = "F19"
keys($5A) = "F20"
keys($73) = "Home"
keys($77) = "End"
keys($74) = "PgUp"
keys($79) = "PgDown"
keys($0A) = "§"
keys($33) = "Del"