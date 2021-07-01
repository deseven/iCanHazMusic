#myName = "iCanHazMusic"
#myVer = "0.2.0"
#myNameVer = #myName + " " + #myVer
#myUserAgent = #myName + "/" + #myVer
#myURL = "https://github.com/deseven/iCanHazMusic"

#geniusToken = "5ssfgWNLZE4ETICJ8EspeGmrVu-Jqp_W0S4q5cJ-Fz_tEKGYimesWxTx9dZ0CO_b"

#lastfmEndpoint = "https://ws.audioscrobbler.com/"
#lastfmAPIKey = "b29cdf01b8e0a255c6a55e68685d6cdf"
#lastfmSecret = "0697a290be37610c1081ccd5f0a0f82a"

#ffprobeURL = "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"
#ffprobeLegal = "https://www.ffmpeg.org/legal.html"
#noffprobeMsg = "Hi! I need ffprobe in order to read tags and other audio metadata, and I've failed to find one in your system. You can install it manually with homebrew (see https://formulae.brew.sh/formula/ffmpeg) or I can download a static copy myself, the question is... should I?"
#failedffprobeMsg = "Failed downloading ffprobe from " + #ffprobeURL + ~"\nPlease try again later or report it to the developer."

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
                ~"\n" +
                ~"What should work in the future: \n" +
                ~" - global hotkeys for playback\n" +
                ~" - album art from tags\n" +
                ~" - playlist entries rearrangement\n" +
                ~" - seekbar\n" +
                ~" - volume control\n" +
                ~" - shuffle\n" +
                ~" - drag'n'drop operations\n" +
                ~"\n" +
                ~"What will never work: \n" +
                ~" - gapless playback (well, maybe someday...)\n" +
                ~" - CUE support\n" +
                ~" - equalizer\n" +
                ~" - tags editing\n" +
                ~" - advanced foobar2000-level customization (i'm too dumb for that, sorry)\n"


#playSymbol = "▶"
#pauseSymbol = "❚ ❚"
#nextSymbol = "▶▶"
#previousSymbol = "◀◀"
#stopSymbol = "■"
#refreshSymbol = "♻"
#processingSymbol = "◔"
#albumSymbol = "⭘"

; workaround for the lack of events in PB sound library
#defaultTimeout = 900
#fastTimeout = 20

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
  filename.s
  nb_streams.l
  nb_programs.l
  format_name.s
  format_long_name.s
  start_time.s
  duration.s
  size.s
  bit_rate.s
  probe_score.l
  Map tags.s()
EndStructure

Structure ffprobe_answer
  format.ffprobe_format
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

Structure settings
  last_played_track_id.i
  alpha_alert_shown_for.s
  lastfm.settingsLastfm
  window.settingsWindow
  playlist.settingsPlaylist
  playback.settingsPlayback
EndStructure

#sep = Chr(10)

#justifyLeft = 0
#justifyRight = 1
#justifyCenter = 2