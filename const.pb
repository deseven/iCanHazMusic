#myName = "iCanHazMusic"

#playSymbol = "▶"
#pauseSymbol = "❚ ❚"
#nextSymbol = "▶▶"
#previousSymbol = "◀◀"
#stopSymbol = "■"
#refreshSymbol = "♻"

Enumeration
  #wnd
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
  #evPlayStart
  #evPlayFinish
  #evLyricsFail
  #evLyricsSuccess
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
  #addDirectory
  #addFile
  #lastfmState
  #lastfmUser
  #playlistMenu
  #playlistReloadTags
  #playlistRemove
  #playlistRemoveAlbum
  #dockMenu
  #dockArtist
  #dockTitle
  #dockPlayPause
  #dockNext
  #dockPrevious
  #dockStop
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
  details.s
  lyrics.s
  albumArt.s
  currentTime.d
  isPaused.b
EndStructure

Structure settings
  last_played_track_id.i
  lastfm_session.s
  lastfm_user.s
EndStructure

#sep = Chr(10)

#geniusToken = "5ssfgWNLZE4ETICJ8EspeGmrVu-Jqp_W0S4q5cJ-Fz_tEKGYimesWxTx9dZ0CO_b"

#lastfmEndpoint = "https://ws.audioscrobbler.com/"
#lastfmAPIKey = "b29cdf01b8e0a255c6a55e68685d6cdf"
#lastfmSecret = "0697a290be37610c1081ccd5f0a0f82a"