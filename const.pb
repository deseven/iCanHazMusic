#myName = "iCanHazMusic"

Enumeration
  #wnd
  #playlist
  #albumArt
  #lyrics
EndEnumeration

Enumeration globalEvents #PB_Event_FirstCustomValue
  #evTagGetSuccess
  #evTagGetFail
  #evTagGetFinish
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
EndEnumeration

Enumeration albumArt
  #defaultAlbumArt
  #currentAlbumArt
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

#sep = Chr(10)

#geniusToken = "5ssfgWNLZE4ETICJ8EspeGmrVu-Jqp_W0S4q5cJ-Fz_tEKGYimesWxTx9dZ0CO_b"