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
  Protected NewList args.s()
  
  Delay(start * 100) ; to spread execution times
  
  For i = start To ListSize(tagsToGet()) - 1
    
    If EXIT
      ProcedureReturn
    EndIf
    
    LockMutex(tagsToGetLock)
    SelectElement(tagsToGet(),i)
    Protected path.s = tagsToGet()\path
    UnlockMutex(tagsToGetLock)
    
    ClearList(args())
    AddElement(args()) : args() = "-v"
    AddElement(args()) : args() = "quiet"
    AddElement(args()) : args() = "-print_format"
    AddElement(args()) : args() = "json"
    AddElement(args()) : args() = "-show_format"
    AddElement(args()) : args() = "-show_streams"
    AddElement(args()) : args() = path
    
    json = RunProgramNative(ffprobe,args())
    
    LockMutex(tagsToGetLock)
    SelectElement(tagsToGet(),i)
    If ParseJSON(0,json)
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
    
    i + numThreads - 1
  Next
  PostEvent(#evTagGetFinish)
EndProcedure

Procedure lyrics(forceGenius)
  Shared nowPlaying,dataDir
  Protected lyricsHash.s = StringFingerprint(nowPlaying\artist + " - " + nowPlaying\title,#PB_Cipher_MD5)
  Protected NewList args.s()
  Protected json.s
  
  If forceGenius = #False And FileSize(dataDir + "/lyrics/" + lyricsHash + ".txt") > 0
    nowPlaying\lyrics = ReadFileFast(dataDir + "/lyrics/" + lyricsHash + ".txt")
    PostEvent(#evLyricsSuccessFile)
    ProcedureReturn
  EndIf

  AddElement(args()) : args() = "-u"
  AddElement(args()) : args() = "-m"
  AddElement(args()) : args() = "lyricsgenius"
  AddElement(args()) : args() = "song"
  AddElement(args()) : args() = nowPlaying\title
  AddElement(args()) : args() = nowPlaying\artist
  AddElement(args()) : args() = "--save"
  AddElement(args()) : args() = "-q"
  SetEnvironmentVariable("GENIUS_ACCESS_TOKEN",#geniusToken)
  Protected res.s = RunProgramNative("/usr/local/bin/python3",args(),dataDir + "/tmp")
  ;Debug res
  If Left(res,6) = "Wrote "
    Protected geniusPath.s = RTrim(RTrim(RTrim(Mid(res,7),#LF$)),".")
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
  Protected NewList args.s()
  AddElement(args()) : args() = "-u"
  AddElement(args()) : args() = "-m"
  AddElement(args()) : args() = "lyricsgenius"
  AddElement(args()) : args() = "-h"
  Protected res.s = RunProgramNative("/usr/local/bin/python3",args(),"")
  If FindString(res,"Download song lyrics from Genius.com")
    ProcedureReturn #True
  EndIf
EndProcedure

Procedure saveSettings()
  Shared dataDir.s
  Shared lastfmSession.s,lastfmUser.s
  Shared lastPlayedID
  Shared alphaAlertShownFor.s
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
  EndIf
  
  Protected object.i = SetJSONObject(JSONValue(json))
  SetJSONInteger(AddJSONMember(object,"last_played_track_id"),lastPlayedID)
  SetJSONString(AddJSONMember(object,"alpha_alert_shown_for"),alphaAlertShownFor)
  
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
  Shared alphaAlertShownFor.s
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
  
  If json
    ExtractJSONStructure(JSONValue(json),@settings,settings,#PB_JSON_NoClear)
    FreeJSON(json)
    
    If Len(settings\web\api_key) = 0 ; in case it exists but empty
      settings\web\api_key = StringFingerprint(Str(Date()),#PB_Cipher_MD5)
    EndIf
    
    If settings\web\web_server_port = 0
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
    EndIf
    
    lastfmSession = settings\lastfm\session
    lastfmUser = settings\lastfm\user
    lastPlayedID = settings\last_played_track_id
    alphaAlertShownFor = settings\alpha_alert_shown_for
    SetGadgetState(#playlist,settings\last_played_track_id)
    
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
    Protected elem = SetJSONObject(AddJSONElement(arr))
    SetJSONString(AddJSONMember(elem,"details"),GetGadgetItemText(#playlist,i,#details))
    SetJSONString(AddJSONMember(elem,"album"),GetGadgetItemText(#playlist,i,#album))
    SetJSONString(AddJSONMember(elem,"duration"),GetGadgetItemText(#playlist,i,#duration))
    SetJSONString(AddJSONMember(elem,"title"),GetGadgetItemText(#playlist,i,#title))
    SetJSONString(AddJSONMember(elem,"artist"),GetGadgetItemText(#playlist,i,#artist))
    SetJSONString(AddJSONMember(elem,"track"),GetGadgetItemText(#playlist,i,#track))
    SetJSONString(AddJSONMember(elem,"file"),GetGadgetItemText(#playlist,i,#file))
    If GetGadgetItemData(#playlist,i)
      SetJSONString(AddJSONMember(elem,"isAlbum"),"yes")
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
        AddGadgetItem(#playlist,i,#sep + 
                                  values("file") + #sep + 
                                  values("track") + #sep + 
                                  values("artist") + #sep + 
                                  values("title") + #sep + 
                                  values("duration") + #sep + 
                                  values("album") + #sep + 
                                  values("details"))
        If values("isAlbum") = "yes"
          SetGadgetItemData(#playlist,i,#True)
          SetGadgetItemText(#playlist,i,#albumSymbol,#status)
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
  Protected fileDir.s = GetPathPart(nowPlaying\path)
  Protected albumArt.s
  
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
  
  If nowPlaying\albumArt <> albumArt
    If albumArt
      If IsImage(#currentAlbumArt)
        SetGadgetState(#albumArt,ImageID(#defaultAlbumArt))
        FreeImage(#currentAlbumArt)
      EndIf
      debugLog ("albumart","loading " + albumArt)
      If LoadImage(#currentAlbumArt,albumArt)
        ResizeImage(#currentAlbumArt,500,500,#PB_Image_Smooth)
        SetGadgetState(#albumArt,ImageID(#currentAlbumArt))
      Else
        SetGadgetState(#albumArt,ImageID(#defaultAlbumArt))
      EndIf
    Else
      debugLog ("albumart","failed to load")
      SetGadgetState(#albumArt,ImageID(#defaultAlbumArt))
      If IsImage(#currentAlbumArt) : FreeImage(#currentAlbumArt) : EndIf
    EndIf
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
    Protected album.s = GetGadgetItemText(#playlist,id,#album)
    Protected i.i
    Protected NewList idsToRemove.i()
    For i = id + 1 To CountGadgetItems(#playlist) - 1
      If GetGadgetItemText(#playlist,i,#album) = album
        AddElement(idsToRemove())
        idsToRemove() = i
      Else
        Break
      EndIf
      CocoaMessage(0,GadgetID(#playlist),"beginUpdates")
      ForEach idsToRemove()
        queueRemove(idsToRemove())
      Next
      CocoaMessage(0,GadgetID(#playlist),"endUpdates")
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
  EndIf
  ForEach playQueue()
    SetGadgetItemText(#playlist,playQueue(),"[" + Str(ListIndex(playQueue()) + 1) + "]",#status)
  Next
EndProcedure

Procedure queueNext()
  Shared playQueue()
  Shared queueEnded.b
  Protected id.i
  If ListSize(playQueue())
    SelectElement(playQueue(),0)
    id = playQueue()
    If ListSize(playQueue()) = 1
      queueEnded = #True
    EndIf
    queueRemove(id)
  Else
    id = -1
  EndIf
  ProcedureReturn id
EndProcedure

Procedure setAlbums(startFrom = 0)
  Protected currentAlbum.s
  Protected newAlbum.s
  Protected color.i
  Protected i.i
  For i = startFrom To CountGadgetItems(#playlist) - 1
    newAlbum = GetGadgetItemText(#playlist,i,#album)
    If newAlbum <> currentAlbum
      currentAlbum = newAlbum
      If Not GetGadgetItemData(#playlist,i)
        AddGadgetItem(#playlist,i,#albumSymbol + #sep + #sep + #sep + GetGadgetItemText(#playlist,i,#artist) + #sep + #sep + #sep + GetGadgetItemText(#playlist,i,#album))
        SetGadgetItemData(#playlist,i,#True)
      EndIf
    EndIf
  Next
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

Procedure getNextTrack()
  Protected nextID.i = -1
  Protected i
  Shared nowPlaying
  Shared cursorFollowsPlayback,playbackFollowsCursor,stopAtQueueEnd,playbackOrder
  Shared currentAlbum,queueEnded
  Shared historyEnabled
  If nowPlaying\ID <> - 1
    nextID = queueNext()
    If nextID = -1 Or nextID >= CountGadgetItems(#playlist) ; if we don't have anything queued
      If queueEnded And stopAtQueueEnd
        queueEnded = #False
        nextID = -1
      ElseIf playbackFollowsCursor And GetGadgetState(#playlist) > -1 And (cursorFollowsPlayback = #False Or GetGadgetState(#playlist) <> nowPlaying\ID)
        nextID = GetGadgetState(#playlist)
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

ProcedureC IsGroupRow(Object.I, Selector.I, TableView.I, Row.I)
  Protected Gadget, IsGroupRow.I
  
  Gadget = CocoaMessage(0, TableView, "tag")
  
  IsGroupRow = GetGadgetItemData(Gadget, Row)
  
  ProcedureReturn IsGroupRow
EndProcedure

Procedure fcgiHandler(port)
  If Not InitFastCGI(port)
    PostEvent(#evFCGIFailed)
    ProcedureReturn
  Else
    PostEvent(#evFCGIStarted)
  EndIf
  
  Shared settings
  Shared fcgiProcessed.b
  Shared *fcgiAlbumArt
  Shared nowPlayingFCGI.nowPlaying
  Protected json.i
  Protected i.i
  
  While WaitFastCGIRequest()
    Protected fcgiAuthOK = #False
    If ReadCGI()
      
      If CountCGICookies() > 0
        For i = 0 To CountCGICookies()-1
          ;Debug CGICookieName(i)
          ;Debug CGICookieValue(CGICookieName(i))
          If CGICookieName(i) = "ichm-auth" And CGICookieValue(CGICookieName(i)) = settings\web\api_key
            fcgiAuthOK = #True
            Break
          EndIf
        Next
      EndIf
      If Not fcgiAuthOK
        WriteCGIHeader(#PB_CGI_HeaderStatus,"401 Unauthorized")
        WriteCGIHeader(#PB_CGI_HeaderContentType,"text/html",#PB_CGI_LastHeader)
        WriteCGIString("Authorization is required. Set cookie ichm-auth with your password.")
        Continue
      EndIf
      
      If CountCGIParameters() = 0
        WriteCGIHeader(#PB_CGI_HeaderContentType,"text/html",#PB_CGI_LastHeader)
        WriteCGIString("Available methods: playpause, next, previous, nextAlbum, previousAlbum, stop, nowplaying, albumart")
      Else
        Select LCase(CGIParameterName(0))
          Case "playpause","next","previous","nextalbum","previousalbum","stop"
            Select LCase(CGIParameterName(0))
              Case "playpause"
                PostEvent(#PB_Event_Gadget,#wnd,#toolbarPlayPause)
              Case "next"
                PostEvent(#PB_Event_Gadget,#wnd,#toolbarNext)
              Case "previous"
                PostEvent(#PB_Event_Gadget,#wnd,#toolbarPrevious)
              Case "nextalbum"
                PostEvent(#PB_Event_Gadget,#wnd,#toolbarNextAlbum)
              Case "previousalbum"
                PostEvent(#PB_Event_Gadget,#wnd,#toolbarPreviousAlbum)
              Case "stop"
                PostEvent(#PB_Event_Gadget,#wnd,#toolbarStop)
            EndSelect
            WriteCGIHeader(#PB_CGI_HeaderContentType,"application/json",#PB_CGI_LastHeader)
            WriteCGIString(~"{\"success\": true}")
          Case "albumart"
            PostEvent(#evFCGIGetAlbumArt)
            While Not fcgiProcessed
              Delay (10)
            Wend
            fcgiProcessed = #False
            If *fcgiAlbumArt
              WriteCGIHeader(#PB_CGI_HeaderContentType,"image/jpeg",#PB_CGI_LastHeader)
              WriteCGIData(*fcgiAlbumArt,MemorySize(*fcgiAlbumArt))
              FreeMemory(*fcgiAlbumArt)
              *fcgiAlbumArt = 0
            EndIf
          Case "play"
            WriteCGIHeader(#PB_CGI_HeaderContentType,"application/json",#PB_CGI_LastHeader)
            WriteCGIString("{}")
          Case "nowplaying"
            WriteCGIHeader(#PB_CGI_HeaderContentType,"application/json",#PB_CGI_LastHeader)
            PostEvent(#evFCGIUpdateNowPlaying)
            While Not fcgiProcessed
              Delay (10)
            Wend
            fcgiProcessed = #False
            json = CreateJSON(#PB_Any)
            nowPlayingFCGI\lyrics = "not available in api mode"
            InsertJSONStructure(JSONValue(json),@nowPlayingFCGI,nowPlaying)
            WriteCGIString(ComposeJSON(json,#PB_JSON_PrettyPrint))
            FreeJSON(json)
          Default
            WriteCGIHeader(#PB_CGI_HeaderStatus,"404 Not found")
            WriteCGIHeader(#PB_CGI_HeaderContentType,"text/html",#PB_CGI_LastHeader)
            WriteCGIString("No such method.")
        EndSelect
      EndIf
    EndIf
  Wend
EndProcedure

Procedure hiawathaWatcher(fcgiPort)
  Shared myDir.s,hiawathaStop.b
  Shared settings
  Protected hiawathaInterface.s = "0.0.0.0"
  Protected hiawathaPort.l = settings\web\web_server_port 
  Shared hiawathaBinary.s,hiawathaRoot.s,hiawathaLogDir.s,hiawathaCfgDir.s,hiawathaPIDFile.s
  Protected hiawathaConfigTemplate = ReadFile(#PB_Any,myDir + "/Web/Server/hiawatha.conf")
  If FileSize(hiawathaCfgDir + "/hiawatha.conf") >= 0 : DeleteFile(hiawathaCfgDir + "/hiawatha.conf",#PB_FileSystem_Force) : EndIf
  Protected hiawathaConfig = CreateFile(#PB_Any,hiawathaCfgDir + "/hiawatha.conf")
  Protected line.s
  
  If (Not IsFile(hiawathaConfigTemplate)) Or (Not IsFile(hiawathaConfig))
    PostEvent(#evHiawathaFailedToStart)
    ProcedureReturn
  EndIf
  
  WriteStringN(hiawathaConfig,"# ATTENTION: This file is automatically generated on each start of iCHM")
  WriteStringN(hiawathaConfig,"set ROOT = " + hiawathaRoot)
  WriteStringN(hiawathaConfig,"set LOGDIR = " + hiawathaLogDir)
  WriteStringN(hiawathaConfig,"set INTERFACE = " + hiawathaInterface)
  WriteStringN(hiawathaConfig,"set HIAWATHA_PORT = " + hiawathaPort)
  WriteStringN(hiawathaConfig,"set ICHM_PORT = " + fcgiPort)
  WriteStringN(hiawathaConfig,"set PIDFILE = " + hiawathaPIDFile)
  WriteStringN(hiawathaConfig,"")
  
  ;Debug myDir + "/Web/Server/hiawatha.conf"
  
  While Eof(hiawathaConfigTemplate) = 0
    line = ReadString(hiawathaConfigTemplate)
    WriteStringN(hiawathaConfig,line)
  Wend
  
  CloseFile(hiawathaConfigTemplate)
  CloseFile(hiawathaConfig)
  
  Protected hiawatha = RunProgram(hiawathaBinary,~"-d -c \"" + hiawathaCfgDir + ~"\"",hiawathaCfgDir,#PB_Program_Open)
  ;Debug hiawathaBinary
  ;Debug "-d -c " + hiawathaCfgDir
  If IsProgram(hiawatha)
    Protected hiawathaPID = ProgramID(hiawatha)
    PostEvent(#evHiawathaStarted)
    Repeat
      Delay(50)
      If hiawathaStop
        ;Debug "stopping hiawatha"
        RunProgram("/bin/kill",Str(hiawathaPID),"") ; send sigterm first
        WaitProgram(hiawatha,10000)
        If ProgramRunning(hiawatha)
          ;Debug "force killing hiawatha"
          KillProgram(hiawatha)
        EndIf
        CloseProgram(hiawatha)
        PostEvent(#evHiawathaStopped)
        ProcedureReturn
      EndIf
      If Not ProgramRunning(hiawatha)
        If ProgramExitCode(hiawatha) = 1
          PostEvent(#evHiawathaFailedBind)
        Else
          PostEvent(#evHiawathaDied)
        EndIf
        CloseProgram(hiawatha)
        ProcedureReturn
      EndIf
    ForEver
  Else
    PostEvent(#evHiawathaFailedToStart)
  EndIf
EndProcedure