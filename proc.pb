Procedure lastfmScrobble()
  Shared nowPlaying
  Shared lastfmSession
  
  Protected api_sig.s
  Protected requestPayload.s
  Protected unixtimeUTC.s
  Protected url.s
  Protected request.HTTPRequestManager::request
    
  unixtimeUTC = Str(unixtimeUTC())
  
  api_sig = StringFingerprint("api_key" + 
                              #lastfmAPIKey + 
                              "artist" + 
                              nowPlaying\artist + 
                              "duration" +
                              Str(nowPlaying\durationSec) +
                              "methodtrack.scrobblesk" + 
                              lastfmSession +
                              "timestamp" +
                              unixtimeUTC +
                              "track" + 
                              nowPlaying\title + 
                              #lastfmSecret,#PB_Cipher_MD5)
  
  url = #lastfmEndpoint + "/2.0/?format=json"
  
  requestPayload = "method=track.scrobble&api_key=" + 
                   #lastfmAPIKey + 
                   "&artist=" +
                   URLEncode(nowPlaying\artist) +
                   "&track=" +
                   URLEncode(nowPlaying\title) +
                   "&duration=" +
                   Str(nowPlaying\durationSec) +
                   "&timestamp=" +
                   unixtimeUTC +
                   "&sk=" +
                   lastfmSession +
                   "&api_sig=" + api_sig
  
  request\type = #PB_HTTP_Post
  request\url = url
  request\textData = requestPayload
  request\finishEvent = #evScrobbleRequestFinished
  request\comment = Str(nowPlaying\ID) + " scrobble"
  
  HTTPRequestManager::request(@request)
EndProcedure

Procedure lastfmUpdateNowPlaying()
  Shared nowPlaying
  Shared lastfmSession
  
  Protected api_sig.s
  Protected requestPayload.s
  Protected url.s
  Protected request.HTTPRequestManager::request
  
  api_sig = StringFingerprint("api_key" + 
                              #lastfmAPIKey + 
                              "artist" + 
                              nowPlaying\artist + 
                              "duration" +
                              Str(nowPlaying\durationSec) +
                              "methodtrack.updateNowPlayingsk" + 
                              lastfmSession + 
                              "track" + 
                              nowPlaying\title + 
                              #lastfmSecret,#PB_Cipher_MD5)
  
  url = #lastfmEndpoint + "/2.0/?format=json"
  
  requestPayload = "method=track.updateNowPlaying&api_key=" + 
                   #lastfmAPIKey + 
                   "&artist=" +
                   URLEncode(nowPlaying\artist) +
                   "&track=" +
                   URLEncode(nowPlaying\title) +
                   "&duration=" +
                   Str(nowPlaying\durationSec) +
                   "&sk=" +
                   lastfmSession +
                   "&api_sig=" + api_sig
  
  request\type = #PB_HTTP_Post
  request\url = url
  request\textData = requestPayload
  request\finishEvent = #evNowPlayingRequestFinished
  request\comment = Str(nowPlaying\ID) + " nowplaying update"
  
  HTTPRequestManager::request(@request)
EndProcedure

Procedure lastfmAuth(lastfmAuthStep.b)
  Shared lastfmToken.s,lastfmSession.s,lastfmUser.s
  Shared lastfmTokenResponse.s,lastfmSessionResponse.s
  Protected api_sig.s,request.i,response.s,json.i,status.s
  Select lastfmAuthStep
    Case #getToken
      lastfmToken = ""
      api_sig = StringFingerprint("api_key" + #lastfmAPIKey + "methodauth.getToken" + #lastfmSecret,#PB_Cipher_MD5)
      request = HTTPRequest(#PB_HTTP_Get,#lastfmEndpoint + "/2.0/?method=auth.getToken&api_key=" + #lastfmAPIKey + "&format=json&api_sig=" + api_sig)
      If request
        response = HTTPInfo(request,#PB_HTTP_Response)
        status = HTTPInfo(request,#PB_HTTP_StatusCode)
        FinishHTTP(request)
        json = ParseJSON(#PB_Any,response)
        If json And status = "200"
          lastfmToken = GetJSONString(GetJSONMember(JSONValue(json),"token"))
          FreeJSON(json)
        EndIf
        If lastfmToken
          ProcedureReturn #True
        Else
          lastfmTokenResponse = "HTTP " + status + ~"\n" + response
        EndIf
      EndIf
    Case #openAuthLink
      RunProgram("open","http://www.last.fm/api/auth/?api_key=" + #lastfmAPIKey + "&token=" + lastfmToken,"")
      ProcedureReturn #True
    Case #getSession
      lastfmSession = ""
      api_sig = StringFingerprint("api_key" + #lastfmAPIKey + "methodauth.getSessiontoken" + lastfmToken + #lastfmSecret,#PB_Cipher_MD5)
      ;Debug "api_key" + #lastfmAPIKey + "methodauth.getSessiontoken" + lastfmToken + #lastfmSecret
      ;Debug api_sig
      request = HTTPRequest(#PB_HTTP_Post,#lastfmEndpoint + "/2.0/?format=json","method=auth.getSession&api_key=" + #lastfmAPIKey + "&token=" + lastfmToken + "&api_sig=" + api_sig)
      If request
        response = HTTPInfo(request,#PB_HTTP_Response)
        status = HTTPInfo(request,#PB_HTTP_StatusCode)
        FinishHTTP(request)
        json = ParseJSON(#PB_Any,response)
        If json And status = "200"
          ;{"session":{"subscriber":0,"name":"...","key":"..."}}
          lastfmSession = GetJSONString(GetJSONMember(GetJSONMember(JSONValue(json),"session"),"key"))
          lastfmUser = GetJSONString(GetJSONMember(GetJSONMember(JSONValue(json),"session"),"name"))
          FreeJSON(json)
        EndIf
        If lastfmSession
          ProcedureReturn #True
        Else
          lastfmSessionResponse = "HTTP " + status + ~"\n" + response
        EndIf
      EndIf
  EndSelect
EndProcedure

Procedure getTags(start.i)
  Shared tagsToGet.track_info()
  Shared numThreads.b
  Shared tagsToGetLock.i
  Shared ffprobe.s
  Protected metadata.ffprobe_answer
  Protected json.s
  Protected NewMap tags_lcase.s()
  Protected i.i
  Protected task.task::task
  
  Delay(start * 100) ; to spread execution times
  
  For i = start To ListSize(tagsToGet()) - 1
    
    If EXIT
      ProcedureReturn
    EndIf
    
    LockMutex(tagsToGetLock)
    SelectElement(tagsToGet(),i)
    Protected path.s = tagsToGet()\path
    UnlockMutex(tagsToGetLock)
    
    ClearStructure(@task,task::task)
    InitializeStructure(@task,task::task)
    With task
      \path = ffprobe
      \wait_program = #True
      \read_output = #True
      
      AddElement(\args()) : \args() = "-v"
      AddElement(\args()) : \args() = "quiet"
      AddElement(\args()) : \args() = "-print_format"
      AddElement(\args()) : \args() = "json"
      AddElement(\args()) : \args() = "-show_format"
      AddElement(\args()) : \args() = "-show_streams"
      AddElement(\args()) : \args() = path
    EndWith
    
    If task::run(@task) And task\exit_code = 0
      
      LockMutex(tagsToGetLock)
      SelectElement(tagsToGet(),i)
      If ParseJSON(0,task\stdout)
        ExtractJSONStructure(JSONValue(0),@metadata.ffprobe_answer,ffprobe_answer)
        
        ClearMap(tags_lcase())
        ForEach metadata\format\tags()
          tags_lcase(LCase(MapKey(metadata\format\tags()))) = metadata\format\tags()
        Next
        
        tagsToGet()\format = metadata\format\format_name
        tagsToGet()\duration = FormatDate("%hh:%ii:%ss",ValF(metadata\format\duration))
        tagsToGet()\bitrate = Val(metadata\format\bit_rate)
        
        If Left(tagsToGet()\duration,2) = "00"
          tagsToGet()\duration = Mid(tagsToGet()\duration,4)
        EndIf
        
        With tagsToGet()\tags
          \album = tags_lcase("album")
          \artist = tags_lcase("artist")
          \title = tags_lcase("title")
          \track = tags_lcase("track")
          
          If Not Len(\artist)
            If tags_lcase("composer")            : \artist = tags_lcase("composer") : EndIf
            If tags_lcase("discogs_artist_list") : \artist = tags_lcase("discogs_artist_list") : EndIf
            If tags_lcase("band")                : \artist = tags_lcase("band") : EndIf
            If tags_lcase("performer")           : \artist = tags_lcase("performer") : EndIf
            If tags_lcase("album_artist")        : \artist = tags_lcase("album_artist") : EndIf
          EndIf
          
          ;Debug tagsToGet()\id
          ;Debug tagsToGet()\tags\title
          
          If tags_lcase("date")
            \album + " (" + tags_lcase("date") + ")"
          ElseIf tags_lcase("year")
            \album + " (" + tags_lcase("year") + ")"
          EndIf
        EndWith
        
        ; last resort - look into streams
        If tagsToGet()\tags\artist = "" Or tagsToGet()\tags\title = ""
          ForEach metadata\streams()
            ClearMap(tags_lcase())
            ForEach metadata\streams()\tags()
              tags_lcase(LCase(MapKey(metadata\streams()\tags()))) = metadata\streams()\tags()
            Next
            With tagsToGet()\tags
              If tags_lcase("album") : \album = tags_lcase("album") : EndIf
              If tags_lcase("artist") : \artist = tags_lcase("artist") : EndIf
              If tags_lcase("title") : \title = tags_lcase("title") : EndIf
              If tags_lcase("track") : \track = tags_lcase("track") : EndIf
              
              If tags_lcase("date")
                \album + " (" + tags_lcase("date") + ")"
              ElseIf tags_lcase("year")
                \album + " (" + tags_lcase("year") + ")"
              EndIf
            EndWith
          Next
        EndIf
        
        FreeJSON(0)
        PostEvent(#evTagGetSuccess,#PB_Ignore,#PB_Ignore,#PB_Ignore,@tagsToGet())
      Else
        PostEvent(#evTagGetFail,#PB_Ignore,#PB_Ignore,#PB_Ignore,@tagsToGet())
      EndIf
      UnlockMutex(tagsToGetLock)
    Else
      Debug task\stderr
      PostEvent(#evTagGetFail,#PB_Ignore,#PB_Ignore,#PB_Ignore,@tagsToGet())
    EndIf
    
    i + numThreads - 1
  Next
  PostEvent(#evTagGetFinish)
EndProcedure

Procedure lyrics(forceGenius)
  Shared nowPlaying,dataDir
  Protected lyricsHash.s = StringFingerprint(nowPlaying\artist + " - " + nowPlaying\title,#PB_Cipher_MD5)
  Protected task.task::task
  Protected json.s
  
  If forceGenius = #False And FileSize(dataDir + "/lyrics/" + lyricsHash + ".txt") > 0
    nowPlaying\lyrics = ReadFileFast(dataDir + "/lyrics/" + lyricsHash + ".txt")
    PostEvent(#evLyricsSuccessFile)
    ProcedureReturn
  EndIf
  
  With task
    \path = "/usr/local/bin/python3"
    \workdir = dataDir + "/tmp"
    \read_output = #True
    
    AddElement(\args()) : \args() = "-u"
    AddElement(\args()) : \args() = "-m"
    AddElement(\args()) : \args() = "lyricsgenius"
    AddElement(\args()) : \args() = "song"
    AddElement(\args()) : \args() = nowPlaying\title
    AddElement(\args()) : \args() = nowPlaying\artist
    AddElement(\args()) : \args() = "--save"
    AddElement(\args()) : \args() = "-q"
    SetEnvironmentVariable("GENIUS_ACCESS_TOKEN",#geniusToken)
  EndWith
  
  If task::run(@task) And Left(task\stdout,6) = "Wrote "
    Protected geniusPath.s = RTrim(RTrim(RTrim(Mid(task\stdout,7),#LF$)),".")
    If FileSize(dataDir + "/tmp/" + geniusPath) > 0
      json = ReadFileFast(dataDir + "/tmp/" + geniusPath)
      If ParseJSON(2,json)
        Protected isInstrumental.b = GetJSONBoolean(GetJSONMember(JSONValue(2),"instrumental"))
        nowPlaying\lyrics = GetJSONString(GetJSONMember(JSONValue(2),"lyrics"))
        If Len(nowPlaying\lyrics) = 0 And isInstrumental
          nowPlaying\lyrics = "[Instrumental]"
        EndIf
        FreeJSON(2)
        WriteFileFast(dataDir + "/lyrics/" + lyricsHash + ".txt",nowPlaying\lyrics)
        PostEvent(#evLyricsSuccessGenius)
        DeleteFile(dataDir + "/tmp/" + geniusPath,#PB_FileSystem_Force)
        ProcedureReturn
      EndIf
    EndIf
  EndIf
  PostEvent(#evLyricsFail)
EndProcedure

Procedure canLoadLyrics()
  Protected task.task::task
  With task
    \path = "/usr/local/bin/python3"
    \read_output = #True
    AddElement(\args()) : \args() = "-u"
    AddElement(\args()) : \args() = "-m"
    AddElement(\args()) : \args() = "lyricsgenius"
    AddElement(\args()) : \args() = "-h"
  EndWith
  If task::run(@task) And FindString(task\stdout,"Download song lyrics from Genius.com")
    ProcedureReturn #True
  EndIf
EndProcedure

Procedure registerShortcuts()
  Shared settings
  globalHK::remove("",0,#True)
  If settings\shortcuts\toggle_shortcut And globalHK::add(settings\shortcuts\toggle_shortcut,#PB_Event_Menu,#wnd,#dockPlayPause)
    If IsWindow(#wndPrefs)
      CocoaMessage(0,GadgetID(#prefsShortcutToggle),"setTextColor:",NSColor($00FF00))
    EndIf
  Else
    If IsWindow(#wndPrefs)
      CocoaMessage(0,GadgetID(#prefsShortcutToggle),"setTextColor:",NSColor($0000FF))
    EndIf
  EndIf
  
  If settings\shortcuts\next_shortcut And globalHK::add(settings\shortcuts\next_shortcut,#PB_Event_Menu,#wnd,#dockNext)
    If IsWindow(#wndPrefs)
      CocoaMessage(0,GadgetID(#prefsShortcutNext),"setTextColor:",NSColor($00FF00))
    EndIf
  Else
    If IsWindow(#wndPrefs)
      CocoaMessage(0,GadgetID(#prefsShortcutNext),"setTextColor:",NSColor($0000FF))
    EndIf
  EndIf
  
  If settings\shortcuts\previous_shortcut And globalHK::add(settings\shortcuts\previous_shortcut,#PB_Event_Menu,#wnd,#dockPrevious)
    If IsWindow(#wndPrefs)
      CocoaMessage(0,GadgetID(#prefsShortcutPrevious),"setTextColor:",NSColor($00FF00))
    EndIf
  Else
    If IsWindow(#wndPrefs)
      CocoaMessage(0,GadgetID(#prefsShortcutPrevious),"setTextColor:",NSColor($0000FF))
    EndIf
  EndIf
  
  If settings\shortcuts\find_shortcut And globalHK::add(settings\shortcuts\find_shortcut,#PB_Event_Menu,#wnd,#playlistFind)
    If IsWindow(#wndPrefs)
      CocoaMessage(0,GadgetID(#prefsShortcutFind),"setTextColor:",NSColor($00FF00))
    EndIf
  Else
    If IsWindow(#wndPrefs)
      CocoaMessage(0,GadgetID(#prefsShortcutFind),"setTextColor:",NSColor($0000FF))
    EndIf
  EndIf
EndProcedure

Procedure saveSettings()
  Shared dataDir.s
  Shared lastfmSession.s,lastfmUser.s
  Shared lastPlayedID
  Shared cursorFollowsPlayback.b,playbackFollowsCursor.b,playbackOrder.b,stopAtQueueEnd.b
  Shared settings.settings
  Protected json.i = CreateJSON(#PB_Any)
  
  If IsWindow(#wndPrefs)
    settings\web\api_key = GetGadgetText(#prefsWebApiKey)
    settings\web\web_server_port = Val(GetGadgetText(#prefsWebPort))
    If GetGadgetState(#prefsWebEnable) = #PB_Checkbox_Checked
      settings\web\use_web_server = #True
    Else
      settings\web\use_web_server = #False
    EndIf
    If GetGadgetState(#prefsUseTerminalNotifier) = #PB_Checkbox_Checked
      settings\use_terminal_notifier = #True
    Else
      settings\use_terminal_notifier = #False
    EndIf
    If GetGadgetState(#prefsUseGenius) = #PB_Checkbox_Checked
      settings\use_genius = #True
    Else
      settings\use_genius = #False
    EndIf
  EndIf
  
  Protected object.i = SetJSONObject(JSONValue(json))
  SetJSONInteger(AddJSONMember(object,"last_played_track_id"),lastPlayedID)
  SetJSONBoolean(AddJSONMember(object,"use_terminal_notifier"),settings\use_terminal_notifier)
  SetJSONBoolean(AddJSONMember(object,"use_genius"),settings\use_genius)
  
  Protected objectShortcuts = SetJSONObject(AddJSONMember(object,"shortcuts"))
  SetJSONString(AddJSONMember(objectShortcuts,"toggle_shortcut"),settings\shortcuts\toggle_shortcut)
  SetJSONString(AddJSONMember(objectShortcuts,"next_shortcut"),settings\shortcuts\next_shortcut)
  SetJSONString(AddJSONMember(objectShortcuts,"previous_shortcut"),settings\shortcuts\previous_shortcut)
  SetJSONString(AddJSONMember(objectShortcuts,"find_shortcut"),settings\shortcuts\find_shortcut)
  
  Protected objectWeb = SetJSONObject(AddJSONMember(object,"web"))
  SetJSONBoolean(AddJSONMember(objectWeb,"use_web_server"),settings\web\use_web_server)
  SetJSONInteger(AddJSONMember(objectWeb,"web_server_port"),settings\web\web_server_port)
  SetJSONString(AddJSONMember(objectWeb,"api_key"),settings\web\api_key)
  
  Protected objectLastfm = SetJSONObject(AddJSONMember(object,"lastfm"))
  SetJSONString(AddJSONMember(objectLastfm,"session"),lastfmSession)
  SetJSONString(AddJSONMember(objectLastfm,"user"),lastfmUser)
  
  Protected objectWindow = SetJSONObject(AddJSONMember(object,"window"))
  SetJSONInteger(AddJSONMember(objectWindow,"x"),WindowX(#wnd))
  SetJSONInteger(AddJSONMember(objectWindow,"y"),WindowY(#wnd))
  SetJSONInteger(AddJSONMember(objectWindow,"width"),WindowWidth(#wnd))
  SetJSONInteger(AddJSONMember(objectWindow,"height"),WindowHeight(#wnd))
  If IsWindowFullscreen(#wnd)
    SetJSONBoolean(AddJSONMember(objectWindow,"fullscreen"),#True)
  Else
    SetJSONBoolean(AddJSONMember(objectWindow,"fullscreen"),#False)
  EndIf
  
  Protected objectPlaylist = SetJSONObject(AddJSONMember(object,"playlist"))
  SetJSONInteger(AddJSONMember(objectPlaylist,"status_width"),GetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,#status))
  SetJSONInteger(AddJSONMember(objectPlaylist,"track_width"),GetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,#track))
  SetJSONInteger(AddJSONMember(objectPlaylist,"artist_width"),GetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,#artist))
  SetJSONInteger(AddJSONMember(objectPlaylist,"title_width"),GetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,#title))
  SetJSONInteger(AddJSONMember(objectPlaylist,"duration_width"),GetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,#duration))
  SetJSONInteger(AddJSONMember(objectPlaylist,"album_width"),GetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,#album))
  SetJSONInteger(AddJSONMember(objectPlaylist,"details_width"),GetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,#details))
  If settings\playlist\dont_group_by_albums
    SetJSONBoolean(AddJSONMember(objectPlaylist,"dont_group_by_albums"),#True)
  Else
    SetJSONBoolean(AddJSONMember(objectPlaylist,"dont_group_by_albums"),#False)
  EndIf
  
  Protected objectPlayback = SetJSONObject(AddJSONMember(object,"playback"))
  If cursorFollowsPlayback
    SetJSONBoolean(AddJSONMember(objectPlayback,"cursor_follows_playback"),#True)
  Else
    SetJSONBoolean(AddJSONMember(objectPlayback,"cursor_follows_playback"),#False)
  EndIf
  If playbackFollowsCursor
    SetJSONBoolean(AddJSONMember(objectPlayback,"playback_follows_cursor"),#True)
  Else
    SetJSONBoolean(AddJSONMember(objectPlayback,"playback_follows_cursor"),#False)
  EndIf
  If stopAtQueueEnd
    SetJSONBoolean(AddJSONMember(objectPlayback,"stop_at_queue_end"),#True)
  Else
    SetJSONBoolean(AddJSONMember(objectPlayback,"stop_at_queue_end"),#False)
  EndIf
  Select playbackOrder
    Case #orderShuffleTracks
      SetJSONString(AddJSONMember(objectPlayback,"playback_order"),"shuffle_tracks")
    Case #orderShuffleAlbums
      SetJSONString(AddJSONMember(objectPlayback,"playback_order"),"shuffle_albums")
    Default
      SetJSONString(AddJSONMember(objectPlayback,"playback_order"),"default")
  EndSelect
  
  WriteFileFast(dataDir + "/settings.json",ComposeJSON(json,#PB_JSON_PrettyPrint))
  ;Debug ComposeJSON(json,#PB_JSON_PrettyPrint)
  FreeJSON(json)
  debugLog("main","settings saved")
EndProcedure

Procedure loadSettings()
  Shared dataDir.s
  Shared lastfmSession.s,lastfmUser.s
  Shared lastPlayedID
  Shared cursorFollowsPlayback.b,playbackFollowsCursor.b,playbackOrder.b,stopAtQueueEnd.b
  Protected settingsData.s = ReadFileFast(dataDir + "/settings.json")
  Protected json.i = ParseJSON(#PB_Any,settingsData)
  Shared settings.settings
  
  ; defaults
  settings\playback\cursor_follows_playback = #True
  settings\playback\playback_follows_cursor = #False
  settings\playback\stop_at_queue_end = #False
  settings\playback\playback_order = "default"
  settings\web\use_web_server = #False
  settings\web\web_server_port = 8008
  settings\use_terminal_notifier = #True
  settings\use_genius = #True
  settings\playlist\dont_group_by_albums = #False
  
  If json
    ExtractJSONStructure(JSONValue(json),@settings,settings,#PB_JSON_NoClear)
    FreeJSON(json)
    
    registerShortcuts()
    
    If Len(Trim(settings\web\api_key)) = 0 ; in case it exists but empty
      settings\web\api_key = StringFingerprint(Str(Date()),#PB_Cipher_MD5)
    EndIf
    
    If settings\web\web_server_port < 1025 Or settings\web\web_server_port > 65534
      settings\web\web_server_port = 8008
    EndIf
    
    If IsWindow(#wndPrefs)
      SetGadgetText(#prefsWebPort,Str(settings\web\web_server_port))
      SetGadgetState(#prefsWebPort,settings\web\web_server_port)
      SetGadgetText(#prefsWebApiKey,settings\web\api_key)
      If settings\web\use_web_server
        SetGadgetState(#prefsWebEnable,#PB_Checkbox_Checked)
        DisableGadget(#prefsWebPort,#True)
      Else
        SetGadgetState(#prefsWebEnable,#PB_Checkbox_Unchecked)
        DisableGadget(#prefsWebPort,#False)
      EndIf
      If settings\use_terminal_notifier
        SetGadgetState(#prefsUseTerminalNotifier,#PB_Checkbox_Checked)
      EndIf
      If settings\use_genius
        SetGadgetState(#prefsUseGenius,#PB_Checkbox_Checked)
      EndIf
    EndIf
    
    lastfmSession = settings\lastfm\session
    lastfmUser = settings\lastfm\user
    lastPlayedID = settings\last_played_track_id
    
    If settings\window\x Or settings\window\y Or settings\window\width Or settings\window\height
      ResizeWindow(#wnd,settings\window\x,settings\window\y,settings\window\width,settings\window\height)
    EndIf
    If settings\window\fullscreen
      EnterWindowFullscreen(#wnd)
    EndIf
    
    If settings\playlist\album_width
      SetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,settings\playlist\album_width,#album)
    EndIf
    If settings\playlist\artist_width
      SetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,settings\playlist\artist_width,#artist)
    EndIf
    If settings\playlist\details_width
      SetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,settings\playlist\details_width,#details)
    EndIf
    If settings\playlist\duration_width
      SetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,settings\playlist\duration_width,#duration)
    EndIf
    If settings\playlist\status_width
      SetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,settings\playlist\status_width,#status)
    EndIf
    If settings\playlist\title_width
      SetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,settings\playlist\title_width,#title)
    EndIf
    If settings\playlist\track_width
      SetGadgetItemAttribute(#playlist,-1,#PB_ListIcon_ColumnWidth,settings\playlist\track_width,#track)
    EndIf
    If settings\playlist\dont_group_by_albums
      SetMenuItemState(#menu,#playlistDontGroupByAlbums,#True)
    Else
      SetMenuItemState(#menu,#playlistDontGroupByAlbums,#False)
    EndIf
    
    If settings\playback\cursor_follows_playback
      cursorFollowsPlayback = #True
      SetMenuItemState(#menu,#playbackCursorFollowsPlayback,#True)
    EndIf
    If settings\playback\playback_follows_cursor
      playbackFollowsCursor = #True
      SetMenuItemState(#menu,#playbackPlaybackFollowsCursor,#True)
    EndIf
    If settings\playback\stop_at_queue_end
      stopAtQueueEnd = #True
      SetMenuItemState(#menu,#playbackStopAtQueueEnd,#True)
    EndIf
    Select settings\playback\playback_order
      Case "shuffle_tracks"
        playbackOrder = #orderShuffleTracks
        SetMenuItemState(#menu,#playbackOrderShuffleTracks,#True)
      Case "shuffle_albums"
        playbackOrder = #orderShuffleAlbums
        SetMenuItemState(#menu,#playbackOrderShuffleAlbums,#True)
      Default
        playbackOrder = #orderDefault
        SetMenuItemState(#menu,#playbackOrderDefault,#True)
    EndSelect
  EndIf
  debugLog("main","settings loaded")
EndProcedure

Procedure saveState()
  Protected playlistSize = CountGadgetItems(#playlist)
  Protected i.i
  Shared dataDir.s
  CreateJSON(1)
  Protected arr = SetJSONArray(JSONValue(1))
  For i = 0 To playlistSize - 1
    If Not GetGadgetItemData(#playlist,i)
      Protected elem = SetJSONObject(AddJSONElement(arr))
      SetJSONString(AddJSONMember(elem,"details"),GetGadgetItemText(#playlist,i,#details))
      SetJSONString(AddJSONMember(elem,"album"),GetGadgetItemText(#playlist,i,#album))
      SetJSONString(AddJSONMember(elem,"duration"),GetGadgetItemText(#playlist,i,#duration))
      SetJSONString(AddJSONMember(elem,"title"),GetGadgetItemText(#playlist,i,#title))
      SetJSONString(AddJSONMember(elem,"artist"),GetGadgetItemText(#playlist,i,#artist))
      SetJSONString(AddJSONMember(elem,"track"),GetGadgetItemText(#playlist,i,#track))
      SetJSONString(AddJSONMember(elem,"file"),GetGadgetItemText(#playlist,i,#file))
    EndIf
  Next
  Protected state.s = ComposeJSON(1,#PB_JSON_PrettyPrint)
  FreeJSON(1)
  If FileSize(dataDir + "/current_state.json") > 0
    If FileSize(dataDir + "/current_state.json.backup") > 0 : DeleteFile(dataDir + "/current_state.json.backup") : EndIf
    RenameFile(dataDir + "/current_state.json",dataDir + "/current_state.json.backup")
  EndIf
  If CreateFile(1,dataDir + "/current_state.json")
    WriteString(1,state)
    CloseFile(1)
    debugLog("main","state saved")
  Else
    MessageRequester(#myName,"Can't save current state to " + dataDir + "/current_state.json",#PB_MessageRequester_Error)
  EndIf
EndProcedure

Procedure loadState()
  Shared dataDir.s
  Protected json.s
  Protected i.i
  Protected NewMap values.s()
  If FileSize(dataDir + "/current_state.json") > 0
    json = ReadFileFast(dataDir + "/current_state.json")
    If ParseJSON(1,json)
      CocoaMessage(0,GadgetID(#playlist),"beginUpdates")
      For i = 0 To JSONArraySize(JSONValue(1)) - 1
        ExtractJSONMap(GetJSONElement(JSONValue(1),i),values())
        If values("isAlbum") = ""
          AddGadgetItem(#playlist,-1,#sep + 
                                     values("file") + #sep + 
                                     values("track") + #sep + 
                                     values("artist") + #sep + 
                                     values("title") + #sep + 
                                     values("duration") + #sep + 
                                     values("album") + #sep + 
                                     values("details"))
        EndIf
      Next
      CocoaMessage(0,GadgetID(#playlist),"endUpdates")
      FreeJSON(1)
      debugLog("main","state loaded")
    EndIf
  EndIf
EndProcedure

Procedure loadAlbumArt()
  Shared nowPlaying
  Shared dataDir
  Shared myDir
  Protected fileDir.s = GetPathPart(nowPlaying\path)
  Protected tmpDir.s = dataDir + "/tmp"
  Protected ffmpeg.s = myDir + "/Tools/ffmpeg-ichm"
  Protected albumArt.s
  Protected internalArt.s = tmpDir + "/" + StringFingerprint(fileDir,#PB_Cipher_MD5) + ".jpg"
  
  If nowPlaying\ID = -1
    nowPlaying\albumArt= ""
    If IsImage(#currentAlbumArt)
      SetGadgetState(#albumArt,ImageID(#defaultAlbumArt))  
      FreeImage(#currentAlbumArt)
    EndIf
    SetGadgetState(#albumArt,ImageID(#defaultAlbumArt))
    ProcedureReturn
  EndIf
  
  If FileSize(fileDir + "folder.jpg") > 0
    albumArt = fileDir + "folder.jpg"
  EndIf
  If FileSize(fileDir + "cover.jpg") > 0
    albumArt = fileDir + "cover.jpg"
  EndIf
  If FileSize(fileDir + "folder.jpeg") > 0
    albumArt = fileDir + "folder.jpeg"
  EndIf
  If FileSize(fileDir + "cover.jpeg") > 0
    albumArt = fileDir + "cover.jpeg"
  EndIf
  If FileSize(fileDir + "folder.png") > 0
    albumArt = fileDir + "folder.png"
  EndIf
  If FileSize(fileDir + "cover.png") > 0
    albumArt = fileDir + "cover.png"
  EndIf
  
  If Not Len(albumArt)
    If ExamineDirectory(0,fileDir,"*.jpg")
      While NextDirectoryEntry(0)
        If DirectoryEntryType(0) = #PB_DirectoryEntry_File
          albumArt = fileDir + DirectoryEntryName(0)
          Break
        EndIf
      Wend
      FinishDirectory(0)
    EndIf
    If ExamineDirectory(0,fileDir,"*.jpeg")
      While NextDirectoryEntry(0)
        If DirectoryEntryType(0) = #PB_DirectoryEntry_File
          albumArt = fileDir + DirectoryEntryName(0)
          Break
        EndIf
      Wend
      FinishDirectory(0)
    EndIf
    If ExamineDirectory(0,fileDir,"*.png")
      While NextDirectoryEntry(0)
        If DirectoryEntryType(0) = #PB_DirectoryEntry_File
          albumArt = fileDir + DirectoryEntryName(0)
          Break
        EndIf
      Wend
      FinishDirectory(0)
    EndIf
  EndIf

  If FileSize(internalArt) > 0
    albumArt = internalArt
  EndIf
  
  If Not Len(albumArt)
    Protected task.task::task
    With task
      \path = ffmpeg
      \workdir = tmpDir
      \wait_program = #True
      AddElement(\args()) : \args() = "-i"
      AddElement(\args()) : \args() = nowPlaying\path
      AddElement(\args()) : \args() = "-an"
      AddElement(\args()) : \args() = "-vcodec"
      AddElement(\args()) : \args() = "copy"
      AddElement(\args()) : \args() = "-y"
      AddElement(\args()) : \args() = internalArt
    EndWith
    If task::run(@task) And task\exit_code = 0 And FileSize(internalArt) > 0
      albumArt = internalArt
    EndIf
  EndIf
  
  If nowPlaying\albumArt <> albumArt
    If IsImage(#currentAlbumArt)
      SetGadgetState(#albumArt,ImageID(#defaultAlbumArt))
      FreeImage(#currentAlbumArt)
    EndIf
    If albumArt
      debugLog ("albumart","loading " + albumArt)
      If LoadImage(#currentAlbumArt,albumArt)
        CopyImage(#currentAlbumArt,#tmpImage)
        ResizeImage(#currentAlbumArt,500,500,#PB_Image_Smooth)
        SetGadgetState(#albumArt,ImageID(#currentAlbumArt))
      Else
        CopyImage(#defaultAlbumArt,#tmpImage)
        debugLog ("albumart","failed to load")
        SetGadgetState(#albumArt,ImageID(#defaultAlbumArt))
      EndIf
    Else
      CopyImage(#defaultAlbumArt,#tmpImage)
      debugLog ("albumart","not found")
      SetGadgetState(#albumArt,ImageID(#defaultAlbumArt))
    EndIf
    ResizeImage(#tmpImage,300,300,#PB_Image_Smooth)
    SaveImage(#tmpImage,tmpDir + "/album-art.jpg",#PB_ImagePlugin_JPEG,7)
    FreeImage(#tmpImage)
    nowPlaying\albumArt = albumArt
  EndIf
EndProcedure

ProcedureC dockMenuHandler(object.i,selector.i,sender.i)
  Shared nowPlaying
  If IsMenu(#dockMenu) : FreeMenu(#dockMenu) : EndIf
  CreateMenu(#dockMenu,0)
  MenuTitle("")
  If nowPlaying\ID <> -1
    MenuItem(#dockArtist,nowPlaying\artist)
    MenuItem(#dockTitle,nowPlaying\title)
    DisableMenuItem(#dockMenu,#dockArtist,#True)
    DisableMenuItem(#dockMenu,#dockTitle,#True)
    MenuBar()
  EndIf
  If nowPlaying\isPaused Or nowPlaying\ID = -1
    MenuItem(#dockPlayPause,"Play")
  Else
    MenuItem(#dockPlayPause,"Pause")
  EndIf
  If nowPlaying\ID <> -1
    MenuItem(#dockNext,"Next Track")
    MenuItem(#dockPrevious,"Previous Track")
    MenuItem(#dockNextAlbum,"Next Album")
    MenuItem(#dockPreviousAlbum,"Previous Album")
    MenuItem(#dockStop,"Stop")
  EndIf
  ProcedureReturn CocoaMessage(0,MenuID(#dockMenu),"objectAtIndex:",0)
EndProcedure

Procedure isParsingCompleted(checkTags.b = #True)
  Shared tagsParserThreads()
  Shared tagsToGet()
  ForEach tagsParserThreads()
    If IsThread(tagsParserThreads())
      ProcedureReturn #False
    EndIf
  Next
  If checkTags And ListSize(tagsToGet())
    ProcedureReturn #False
  EndIf
  ProcedureReturn #True
EndProcedure

Procedure updateNowPlaying(currentTime.i,duration.i)
  Protected currentTimeFormatted.s
  Protected durationFormatted.s
  If duration >= 3600
    currentTimeFormatted = FormatDate("%hh:%ii:%ss",currentTime)
    durationFormatted = FormatDate("%hh:%ii:%ss",duration)
  Else
    currentTimeFormatted = FormatDate("%ii:%ss",currentTime)
    durationFormatted = FormatDate("%ii:%ss",duration)
  EndIf
  SetGadgetText(#nowPlayingDuration,currentTimeFormatted + " / " + durationFormatted)
  Protected part.f = duration / 100
  If part > 0
    SetGadgetState(#nowPlayingProgress,currentTime / part)
  EndIf
EndProcedure

Procedure queueClear()
  Shared playQueue()
  Shared nowPlaying
  ForEach playQueue()
    If playQueue() <> nowPlaying\ID
      SetGadgetItemText(#playlist,playQueue(),"",#status)
    EndIf
  Next
  ClearList(playQueue())
EndProcedure

Procedure isQueued(id.i)
  Shared playQueue()
  If GetGadgetItemData(#playlist,id)
    Protected album.s = GetGadgetItemText(#playlist,id,#album)
    Protected i.i
    For i = id + 1 To CountGadgetItems(#playlist) - 1
      If GetGadgetItemText(#playlist,i,#album) = album
        If isQueued(i)
          ProcedureReturn #True
        EndIf
      Else
        Break
      EndIf
    Next
  Else
    ForEach playQueue()
      If playQueue() = id
        ProcedureReturn #True
      EndIf
    Next
  EndIf
EndProcedure

Procedure queueAdd(id.i)
  Shared playQueue()
  Shared nowPlaying
  If Not isQueued(id)
    If GetGadgetItemData(#playlist,id)
      Protected album.s = GetGadgetItemText(#playlist,id,#album)
      Protected i.i
      For i = id + 1 To CountGadgetItems(#playlist) - 1
        If GetGadgetItemText(#playlist,i,#album) = album
          queueAdd(i)
        Else
          Break
        EndIf
      Next
    Else
      If id <> nowPlaying\ID
        AddElement(playQueue())
        playQueue() = id
        SetGadgetItemText(#playlist,playQueue(),"[" + Str(ListSize(playQueue())) + "]",#status)
      EndIf
    EndIf
  EndIf
EndProcedure

Procedure queueRemove(id.i)
  Shared playQueue()
  Shared nowPlaying
  If GetGadgetItemData(#playlist,id)
    Protected i.i
    Protected NewList idsToRemove.i()
    For i = id + 1 To CountGadgetItems(#playlist) - 1
      If Not GetGadgetItemData(#playlist,i) 
        AddElement(idsToRemove())
        idsToRemove() = i
      Else
        Break
      EndIf
    Next
    ForEach idsToRemove()
      queueRemove(idsToRemove())
    Next
  Else
    ForEach playQueue()
      If playQueue() = id
        If id <> nowPlaying\ID
          SetGadgetItemText(#playlist,playQueue(),"",#status)
        EndIf
        DeleteElement(playQueue())
        Break
      EndIf
    Next
    ForEach playQueue()
      SetGadgetItemText(#playlist,playQueue(),"[" + Str(ListIndex(playQueue()) + 1) + "]",#status)
    Next
  EndIf
EndProcedure

Procedure queueNext(peek.b = #False)
  Shared playQueue()
  Shared queueEnded.b
  Protected id.i
  If ListSize(playQueue())
    SelectElement(playQueue(),0)
    id = playQueue()
    If ListSize(playQueue()) = 1
      queueEnded = #True
    EndIf
    If Not peek
      queueRemove(id)
    EndIf
  Else
    id = -1
  EndIf
  ProcedureReturn id
EndProcedure

Procedure setAlbums()
  Protected currentAlbum.s
  Protected newAlbum.s
  Protected color.i
  Protected i.i,j.i
  Shared settings
  CocoaMessage(0,GadgetID(#playlist),"beginUpdates")
  j = CountGadgetItems(#playlist) - 1
  For i = 0 To j
    newAlbum = GetGadgetItemText(#playlist,i,#album)
    If newAlbum <> currentAlbum
      currentAlbum = newAlbum
      If settings\playlist\dont_group_by_albums
        If GetGadgetItemData(#playlist,i)
          RemoveGadgetItem(#playlist,i)
          j - 1
        EndIf
      Else
        If Not GetGadgetItemData(#playlist,i)
          AddGadgetItem(#playlist,i,#albumSymbol + #sep + #sep + #sep + GetGadgetItemText(#playlist,i,#artist) + #sep + #sep + #sep + GetGadgetItemText(#playlist,i,#album))
          j + 1
          SetGadgetItemData(#playlist,i,#True)
        EndIf
      EndIf
    EndIf
  Next
  CocoaMessage(0,GadgetID(#playlist),"endUpdates")
EndProcedure

Procedure getNextAlbum()
  Protected nextID.i = -1
  Protected randomAlbum,album,i
  Shared playbackOrder
  Shared currentAlbum,numAlbums
  Shared nowPlaying
  Select playbackOrder
    Case #orderShuffleAlbums
      numAlbums = 0
      For i = 0 To CountGadgetItems(#playlist) - 1
        If GetGadgetItemData(#playlist,i)
          numAlbums + 1
        EndIf
      Next
      randomAlbum = Random(numAlbums,1)
      album = 0
      For i = 0 To CountGadgetItems(#playlist) - 1
        If GetGadgetItemData(#playlist,i)
          album + 1
          If album = randomAlbum
            nextID = i + 1
            currentAlbum = GetGadgetItemText(#playlist,nextID,#album)
            Break
          EndIf
        EndIf
      Next
    Default
      If nowPlaying\ID <> -1
        For i = nowPlaying\ID To CountGadgetItems(#playlist)-1
          If Not GetGadgetItemData(#playlist,i)
            If currentAlbum <> GetGadgetItemText(#playlist,i,#album)
              currentAlbum = GetGadgetItemText(#playlist,i,#album)
              nextID = i
              Break
            EndIf
          EndIf
        Next
      EndIf
  EndSelect
  ProcedureReturn nextID
EndProcedure

Procedure getPreviousAlbum()
  Protected nextID.i = -1
  Protected i,j
  Shared currentAlbum
  Shared nowPlaying
  If nowPlaying\ID <> - 1
    currentAlbum = GetGadgetItemText(#playlist,nowPlaying\ID,#album)
    For i = nowPlaying\ID To 0 Step -1
      If GetGadgetItemData(#playlist,i) = #False And currentAlbum <> GetGadgetItemText(#playlist,i,#album)
        currentAlbum = GetGadgetItemText(#playlist,i,#album)
        For j = i To 0 Step -1
          If GetGadgetItemData(#playlist,j)
            nextID = j + 1
            Break 2
          EndIf
        Next
      EndIf
    Next
  EndIf
  ProcedureReturn nextID
EndProcedure

Procedure getNextTrack(peek.b = #False)
  Protected nextID.i = -1
  Protected i
  Shared nowPlaying
  Shared cursorFollowsPlayback,playbackFollowsCursor,stopAtQueueEnd,playbackOrder
  Shared currentAlbum,queueEnded
  Shared historyEnabled
  If nowPlaying\ID <> - 1
    nextID = queueNext(peek)
    If nextID = -1 Or nextID >= CountGadgetItems(#playlist) ; if we don't have anything queued
      If queueEnded And stopAtQueueEnd
        If Not peek
          queueEnded = #False
        EndIf
        nextID = -1
      ElseIf playbackFollowsCursor And GetGadgetState(#playlist) > -1 And (cursorFollowsPlayback = #False Or GetGadgetState(#playlist) <> nowPlaying\ID)
        If GetGadgetItemData(#playlist,GetGadgetState(#playlist))
          nextID = GetGadgetState(#playlist) + 1
        Else
          nextID = GetGadgetState(#playlist)
        EndIf
      Else
        Select playbackOrder
          Case #orderShuffleTracks
            nextID = Random(CountGadgetItems(#playlist)-1,0)
            If GetGadgetItemData(#playlist,nextID)
              nextID + 1
            EndIf
          Case #orderShuffleAlbums
            If nowPlaying\ID < CountGadgetItems(#playlist) - 1 And GetGadgetItemText(#playlist,nowPlaying\ID + 1,#album) <> currentAlbum
              nextID = getNextAlbum()
            Else
              nextID = nowPlaying\ID + 1
            EndIf
          Default
            If nowPlaying\ID < CountGadgetItems(#playlist) - 1
              If GetGadgetItemData(#playlist,nowPlaying\ID + 1)
                nextID = nowPlaying\ID + 2
              Else
                nextID = nowPlaying\ID + 1
              EndIf
            Else
              nextID = -1
            EndIf
        EndSelect
      EndIf
    EndIf
  EndIf
  historyEnabled = #True
  ProcedureReturn nextID
EndProcedure

Procedure getPreviousTrack()
  Shared nowPlaying
  Shared history()
  Shared currentAlbum
  Shared historyEnabled
  Protected nextID.i = -1
  If ListSize(history()) >= 2
    LastElement(history())
    DeleteElement(history())
    LastElement(history())
    nextID = history()
    DeleteElement(history())
  Else
    historyEnabled = #False
    ClearList(history())
  EndIf
  If nowPlaying\ID > 0 And historyEnabled = #False
    If GetGadgetItemData(#playlist,nowPlaying\ID - 1)
      If nowPlaying\ID - 2 >= 0
        nextID = nowPlaying\ID - 2
      EndIf
    Else
      nextID = nowPlaying\ID - 1
    EndIf
    currentAlbum = GetGadgetItemText(#playlist,nextID,#album)
  EndIf
  ProcedureReturn nextID
EndProcedure

;ProcedureC IsGroupRow(Object.I, Selector.I, TableView.I, Row.I)
;  ProcedureReturn GetGadgetItemData(#playlist, Row)
;EndProcedure

ProcedureC CellDisplayCallback(Object.I, Selector.I, TableView.I, Cell.I, *Column, Row.I)
  Protected LineFrame.NSRect
  Protected RowFrame.NSRect
  Protected TextSize.NSSize
  Protected CellFrame.NSRect
  Protected BoldFontSize.CGFloat = 15.0
  Protected FontSize.CGFloat = 13.0
  Static SystemFont.i
  Static BoldSystemFont.i
  Protected Column.i = CocoaMessage(0,CocoaMessage(0,TableView,"tableColumns"),"indexOfObject:",*Column)
  Protected CellText.s = GetGadgetItemText(#playlist,Row,Column)
  
  If Not BoldSystemFont
    BoldSystemFont = CocoaMessage(0, 0, "NSFont boldSystemFontOfSize:@", @BoldFontSize)
    CocoaMessage(0, BoldSystemFont, "retain")
  EndIf
  
  If Not SystemFont
    SystemFont = CocoaMessage(0, 0, "NSFont systemFontOfSize:@", @FontSize)
    CocoaMessage(0, SystemFont, "retain")
  EndIf
  
  CocoaMessage(0, Cell, "_setVerticallyCentered:", #YES)
  
  If GetGadgetItemData(#playlist,Row)
    If Column = #status
      ;CocoaMessage(0, Cell, "setBackgroundStyle:", 2)
      ;CocoaMessage(0, Cell, "setDrawsBackground:", #YES)
      ;CocoaMessage(0, Cell, "setBackgroundColor:",CocoaMessage(0, 0, "NSColor redColor"))
      CocoaMessage(@CellFrame, TableView, "frameOfCellAtColumn:", Column, "row:", Row)
      CocoaMessage(@TextSize, Cell, "cellSize")
      CocoaMessage(@RowFrame, GadgetID(#playlist), "rectOfRow:", Row)
      ;LineFrame\origin\x = CellFrame\origin\x + TextSize\width + 10
      ;LineFrame\origin\y =  CellFrame\origin\y + CellFrame\size\height / 2 + 1
      LineFrame\origin\x = CellFrame\origin\x-10
      LineFrame\origin\y =  CellFrame\origin\y
      LineFrame\size\height = RowFrame\size\height
      LineFrame\size\width = RowFrame\size\width+20
      CocoaMessage(0, CocoaMessage(0, 0, "NSColor grayColor"), "setStroke")
      CocoaMessage(0, 0, "NSBezierPath strokeRect:@", @LineFrame)
      CocoaMessage(0, Cell,
                   "drawInteriorWithFrame:@", @LineFrame,
                   "inView:", TableView)
    EndIf
    
    CocoaMessage(0, Cell,
                 "setTitle:", CocoaMessage(0, Cell, "title"))
    CocoaMessage(0, Cell, 
                 "setTextColor:", CocoaMessage(0, 0, "NSColor secondaryLabelColor"))
    CocoaMessage(0, Cell,
                 "setFont:", BoldSystemFont)
  Else
    CocoaMessage(0, Cell, 
                 "setTextColor:", CocoaMessage(0, 0, "NSColor labelColor"))
    CocoaMessage(0, Cell,
                 "setFont:", SystemFont)
    Select Column
      Case #status
        CocoaMessage(0, Cell, "setAlignment:", #justifyCenter)
      Case #track
        CocoaMessage(0, Cell, "setAlignment:", #justifyRight)
      Case #duration
        CocoaMessage(0, Cell, "setAlignment:", #justifyCenter)
      Case #details
        CocoaMessage(0, Cell, "setAlignment:", #justifyRight)
    EndSelect
  EndIf
  
  CocoaMessage(0, Cell, "setStringValue:$", @CellText)
  
EndProcedure

Procedure playlistMoveItem(iFrom,iTo)
  If iFrom < iTo
    iTo + 1
  EndIf
  AddGadgetItem(#playlist,iTo,#sep + 
                              GetGadgetItemText(#playlist,iFrom,#file) + #sep + 
                              GetGadgetItemText(#playlist,iFrom,#track) + #sep + 
                              GetGadgetItemText(#playlist,iFrom,#artist) + #sep + 
                              GetGadgetItemText(#playlist,iFrom,#title) + #sep + 
                              GetGadgetItemText(#playlist,iFrom,#duration) + #sep + 
                              GetGadgetItemText(#playlist,iFrom,#album) + #sep + 
                              GetGadgetItemText(#playlist,iFrom,#details))
  If iFrom > iTo
    RemoveGadgetItem(#playlist,iFrom+1)
  Else
    RemoveGadgetItem(#playlist,iFrom)
  EndIf
EndProcedure

Procedure playlistMove(direction.b,what.i = -1)
  Protected i
  Protected moveStart,moveEnd,moveTo,moveToOrig
  If what = -1
    moveStart = GetGadgetState(#playlist)
  Else
    moveStart = what
  EndIf
  If moveStart <> -1
    If direction = #moveUp
      If GetGadgetItemData(#playlist,moveStart) ; if moving an album
        If moveStart > 0                        ; if it's not the first one already
          RemoveGadgetItem(#playlist,moveStart)
          
          For i = moveStart To CountGadgetItems(#playlist)-1 ; determining what to move
            If GetGadgetItemData(#playlist,i)
              moveEnd = i-1
              Break
            EndIf
          Next
          If moveEnd = 0 : moveEnd = CountGadgetItems(#playlist)-1 : EndIf
          
          For i = moveStart-1 To 0 Step -1 ; determining where to move
            If GetGadgetItemData(#playlist,i)
              moveTo = i
              Break
            EndIf
          Next
                    
          moveToOrig = moveTo
          CocoaMessage(0,GadgetID(#playlist),"beginUpdates")
          For i = moveStart To moveEnd
            playlistMoveItem(i,moveTo)
            moveTo + 1
          Next
          CocoaMessage(0,GadgetID(#playlist),"endUpdates")
          
          setAlbums()
          SetGadgetState(#playlist,moveToOrig)
        EndIf
      Else
        If moveStart-1 >= 0 And Not GetGadgetItemData(#playlist,moveStart-1)
          playlistMoveItem(moveStart,moveStart-1)
          SetGadgetState(#playlist,moveStart-1)
        EndIf
      EndIf
    Else ; moving down
      If GetGadgetItemData(#playlist,moveStart) ; if moving an album
        
        ; i'm too tired so instead of moving the album down we will select the next album and move it up
        ; SMORT!
        
        For i = moveStart+1 To CountGadgetItems(#playlist)-1
          If GetGadgetItemData(#playlist,i)
            playlistMove(#moveUp,i)
            Break
          EndIf
        Next
        
        ; now just to determine what should be the active item...
        For i = moveStart+1 To CountGadgetItems(#playlist)-1
          If GetGadgetItemData(#playlist,i)
            SetGadgetState(#playlist,i)
            Break
          EndIf
        Next
        
      Else
        If moveStart+1 <= CountGadgetItems(#playlist)-1 And Not GetGadgetItemData(#playlist,moveStart+1)
          playlistMoveItem(moveStart,moveStart+1)
          SetGadgetState(#playlist,moveStart+1)
        EndIf
      EndIf
    EndIf
  EndIf
EndProcedure

Procedure playbackNotification()
  Shared nowPlaying
  Shared settings
  Shared dataDir
  Protected task.task::task
  If settings\use_terminal_notifier
    If FileSize(#terminalNotifier) > 0
      With task
        \path = #terminalNotifier
        AddElement(\args()) : \args() = "-sender"
        AddElement(\args()) : \args() = #myID
        AddElement(\args()) : \args() = "-group"
        AddElement(\args()) : \args() = "ichm"
        AddElement(\args()) : \args() = "-title"
        AddElement(\args()) : \args() = nowPlaying\title
        AddElement(\args()) : \args() = "-subtitle"
        AddElement(\args()) : \args() = nowPlaying\artist
        AddElement(\args()) : \args() = "-message"
        AddElement(\args()) : \args() = nowPlaying\details
        If FileSize(nowPlaying\albumArt) > 0
          AddElement(\args()) : \args() = "-contentImage"
          AddElement(\args()) : \args() = dataDir + "/tmp/album-art.jpg"
        EndIf
      EndWith
      task::run(@task)
    EndIf
  EndIf
EndProcedure

Procedure webHandler(port.l)
  Protected activity.i = BeginWork(#NSActivityBackground,"iCHM web server")
  Protected webEvent.i
  Protected webConnection.i
  Protected webConnectionIP.i
  Protected webConnectionPort.l
  Protected *webBuffer
  Protected *payloadBuffer
  Protected webRequestRaw.s
  Protected webRequest.s
  Protected webRequestType.s
  Protected webRequestQuery.s
  Protected webRequestParams.s
  Protected webRequestApiKey.s
  Protected webResponse.s
  Protected webPayload.s
  Protected payloadIsBinary.b
  Protected payloadIsAlbumArt.b
  Protected webJSON.i
  Protected apikeyStart.i,apikeyEnd.i
  Protected file.i
  Shared myDir.s
  Shared dataDir.s
  Shared webStop.b
  Shared webProcessed.b
  Shared webNowPlaying.nowPlaying
  Shared settings.settings
  webProcessed = #False
  
  Protected sleepTime.l = 50
  Protected isSleeping = #False
  Protected lastEvent.i
  
  Protected server.i = CreateNetworkServer(#PB_Any,port,#PB_Network_TCP|#PB_Network_IPv4)
  If server
    PostEvent(#evWebStarted)
    Repeat
      webEvent = NetworkServerEvent()
      Select webEvent
        Case #PB_NetworkEvent_None
          If (Not isSleeping) And (ElapsedMilliseconds() - lastEvent > 10000)
            isSleeping = #True : sleepTime = 1000
            PostEvent(#evWebSleep)
          EndIf
        Case #PB_NetworkEvent_Connect
          lastEvent = ElapsedMilliseconds()
          isSleeping = #False : sleepTime = 50
        Case #PB_NetworkEvent_Data
          lastEvent = ElapsedMilliseconds()
          isSleeping = #False : sleepTime = 50
          webConnection = EventClient()
          webConnectionIP = GetClientIP(webConnection)
          webConnectionPort = GetClientPort(webConnection)
          *webBuffer = AllocateMemory(65535)
          ReceiveNetworkData(webConnection,*webBuffer,65534)
          webRequestRaw = PeekS(*webBuffer,-1,#PB_UTF8)
          FreeMemory(*webBuffer)
          *webBuffer = 0
          webRequest = StringField(webRequestRaw,1,~"\n")
          webRequestType = LCase(StringField(webRequest,1," "))
          webRequestQuery = StringField(webRequest,2," ")
          webRequestParams = StringField(webRequestQuery,2,"?")
          webRequestQuery = LCase(StringField(webRequestQuery,1,"?"))
          webRequestQuery = ReplaceString(webRequestQuery,"..","")
          webResponse = ""
          webPayload = ""
          webRequestApiKey = ""
          *payloadBuffer = 0
          payloadIsBinary = #False
          payloadIsAlbumArt = #False
          If webRequestType = "get" And webRequestQuery
            
            PostEvent(#evWebRequest,0,webConnection,webConnectionIP,webConnectionPort)
            
            apikeyStart = FindString(webRequestRaw,"x-api-key",1,#PB_String_NoCase)
            If apikeyStart
              apikeyStart + 10
              apikeyEnd = FindString(webRequestRaw,~"\n",apikeyStart)
              If apikeyEnd
                webRequestApiKey = Mid(webRequestRaw,apikeyStart,apikeyEnd-apikeyStart)
                webRequestApiKey = Trim(webRequestApiKey)
                webRequestApiKey = Trim(webRequestApiKey,#CR$)
                webRequestApiKey = Trim(webRequestApiKey,#LF$)
              EndIf
            EndIf
            If FindString(webRequestQuery,"/api/") = 1 And Len(webRequestQuery) > 5 And webRequestApiKey <> settings\web\api_key
              webPayload = "Unauthorized"
              webResponse = "HTTP/1.1 401 Unauthorized" + #CRLF$ + "Content-Type: text/plain"
            Else
              
              Select webRequestQuery
                  
                Case "/"
                  webPayload = ReadFileFast(myDir + "/Web/Data/index.html")
                  webResponse = "HTTP/1.1 200 OK" + #CRLF$ + "Content-Type: text/html"
                  
                Case "/api","/api/"
                  webPayload = #myNameVer + ~" API\n" +
                               ~"---------------\n" + 
                               ~"Available GET methods:\n" + 
                               ~"/api/play-pause\n" +
                               ~"/api/next\n" +
                               ~"/api/previous\n" +
                               ~"/api/next-album\n" +
                               ~"/api/previous-album\n" +
                               ~"/api/stop\n" +
                               ~"/api/now-playing\n" +
                               ~"/api/album-art\n" +
                               ~"---------------\n" +
                               ~"Don't forget to send X-Api-Key header!\n"
                  webResponse = "HTTP/1.1 200 OK" + #CRLF$ + "Content-Type: text/plain"
                  
                Case "/api/play-pause"
                  PostEvent(#PB_Event_Gadget,#wnd,#toolbarPlayPause)
                  webResponse = "HTTP/1.1 200 OK" + #CRLF$ + "Content-Type: text/html"
                  
                Case "/api/next"
                  PostEvent(#PB_Event_Gadget,#wnd,#toolbarNext)
                  webResponse = "HTTP/1.1 200 OK" + #CRLF$ + "Content-Type: text/html"
                  
                Case "/api/previous"
                  PostEvent(#PB_Event_Gadget,#wnd,#toolbarPrevious)
                  webResponse = "HTTP/1.1 200 OK" + #CRLF$ + "Content-Type: text/html"
                  
                Case "/api/next-album"
                  PostEvent(#PB_Event_Gadget,#wnd,#toolbarNextAlbum)
                  webResponse = "HTTP/1.1 200 OK" + #CRLF$ + "Content-Type: text/html"
                  
                Case "/api/previous-album"
                  PostEvent(#PB_Event_Gadget,#wnd,#toolbarPreviousAlbum)
                  webResponse = "HTTP/1.1 200 OK" + #CRLF$ + "Content-Type: text/html"
                  
                Case "/api/stop"
                  PostEvent(#PB_Event_Gadget,#wnd,#toolbarStop)
                  webResponse = "HTTP/1.1 200 OK" + #CRLF$ + "Content-Type: text/html"
                  
                Case "/api/now-playing"
                  PostEvent(#evWebUpdateNowPlaying)
                  While Not webProcessed
                    Delay(10)
                  Wend
                  webProcessed = #False
                  webJSON = CreateJSON(#PB_Any)
                  webNowPlaying\lyrics = "[not available in api]"
                  InsertJSONStructure(JSONValue(webJSON),@webNowPlaying,nowPlaying)
                  webPayload = ComposeJSON(webJSON,#PB_JSON_PrettyPrint)
                  FreeJSON(webJSON)
                  webResponse = "HTTP/1.1 200 OK" + #CRLF$ + "Content-Type: application/json"
                  
                Case "/album-art.jpg"
                  PostEvent(#evWebGetAlbumArt)
                  While Not webProcessed
                    Delay(10)
                  Wend
                  webProcessed = #False
                  payloadIsBinary = #True
                  payloadIsAlbumArt = #True
                  webResponse = "HTTP/1.1 200 OK" + #CRLF$ + "Content-Type: image/jpeg"
                  
                Default
                  If FileSize(myDir + "/Web/Data/" + webRequestQuery) > 0
                    webResponse = "HTTP/1.1 200 OK" + #CRLF$
                    
                    Select GetExtensionPart(myDir + "/Web/Data/" + webRequestQuery)
                      Case "htm","html"
                        webResponse + "Content-Type: text/html"
                      Case "css"
                        webResponse + "Content-Type: text/css"
                      Case "js"
                        webResponse + "Content-Type: text/javascript"
                      Default
                        payloadIsBinary = #True
                    EndSelect
                    
                    If payloadIsBinary
                      Select GetExtensionPart(myDir + "/Web/Data/" + webRequestQuery)
                        Case "jpg","jpeg"
                          webResponse + "Content-Type: image/jpeg"
                        Case "png"
                          webResponse + "Content-Type: image/png"
                        Default
                          webResponse + "Content-Type: application/octet-stream"
                      EndSelect
                    Else
                      webPayload = ReadFileFast(myDir + "/Web/Data/" + webRequestQuery)
                    EndIf
                  Else
                    webPayload = "Not Found"
                    webResponse = "HTTP/1.1 404 Not Found" + #CRLF$ + "Content-Type: text/plain"
                  EndIf
              EndSelect
            EndIf
          Else
            ;Debug webRequestRaw
            webPayload = "Bad Request"
            webResponse = "HTTP/1.1 400 Bad Request" + #CRLF$ + "Content-Type: text/plain"
          EndIf
          
          If payloadIsBinary
            SendNetworkString(webConnection,webResponse + #CRLF$ + "Connection: close" + #CRLF$ + #CRLF$,#PB_UTF8)
            If payloadIsAlbumArt
              file = ReadFile(#PB_Any,dataDir + "/tmp/album-art.jpg")
            Else
              file = ReadFile(#PB_Any,myDir + "/Web/Data/" + webRequestQuery)
            EndIf
            If file And Lof(file) < 64000
              *payloadBuffer = AllocateMemory(Lof(file))
              ReadData(file,*payloadBuffer,Lof(file))
              CloseFile(file)
              SendNetworkData(webConnection,*payloadBuffer,MemorySize(*payloadBuffer))
              FreeMemory(*payloadBuffer)
            EndIf
          Else
            SendNetworkString(webConnection,webResponse + #CRLF$ + "Connection: close" + #CRLF$ + #CRLF$ + webPayload,#PB_UTF8)
          EndIf
          CloseNetworkConnection(webConnection)
      EndSelect
      Delay(sleepTime)
    Until webStop = #True
    CloseNetworkServer(server)
  EndIf
  
  If activity
    EndWork(activity)
  EndIf
  PostEvent(#evWebStopped)
EndProcedure

Procedure playFinishHandler()
  Shared preloadAP,lastfmSession,nowPlaying
  If preloadAP
    ; not needed since pb-macos-audioplayer r6
    ;audioplayer::play(preloadAP)
  EndIf
  debugLog("playback","track ended")
  If lastfmSession
    debugLog("lastfm","scrobbling " + Str(nowPlaying\ID))
    lastfmScrobble()
  EndIf
  PostEvent(#PB_Event_Gadget,#wnd,#toolbarNext)
EndProcedure