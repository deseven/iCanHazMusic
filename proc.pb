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
  Protected json.i = CreateJSON(#PB_Any)
  
  Protected object.i = SetJSONObject(JSONValue(json))
  SetJSONInteger(AddJSONMember(object,"last_played_track_id"),lastPlayedID)
  SetJSONString(AddJSONMember(object,"alpha_alert_shown_for"),alphaAlertShownFor)
  
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
  Protected settings.settings
  
  ; defaults
  settings\playback\cursor_follows_playback = #True
  settings\playback\playback_follows_cursor = #False
  settings\playback\stop_at_queue_end = #False
  settings\playback\playback_order = "default"
  
  If json
    ExtractJSONStructure(JSONValue(json),@settings,settings,#PB_JSON_NoClear)
    FreeJSON(json)
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
    If IsImage(#currentAlbumArt) : FreeImage(#currentAlbumArt) : EndIf
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
      If IsImage(#currentAlbumArt) : FreeImage(#currentAlbumArt) : EndIf
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

Procedure getNextTrack()
  Protected nextID.i = -1
  Protected randomAlbum,album,i
  Shared nowPlaying
  Shared cursorFollowsPlayback,playbackFollowsCursor,stopAtQueueEnd,playbackOrder
  Shared numAlbums,currentAlbum,queueEnded
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

Procedure.s findffprobe()
  Protected ffprobe.s
  Protected NewList possibleLocations.s()
  Shared ffprobeVer.s
  Shared dataDir.s
  AddElement(possibleLocations()) : possibleLocations() = dataDir + "/ffprobe"
  AddElement(possibleLocations()) : possibleLocations() = "/usr/local/bin/ffprobe"
  AddElement(possibleLocations()) : possibleLocations() = "/usr/bin/ffprobe"
  AddElement(possibleLocations()) : possibleLocations() = "/bin/ffprobe"
  ForEach possibleLocations()
    If FileSize(possibleLocations()) > 0 And ((GetFileAttributes(possibleLocations()) & #PB_FileSystem_ExecAll) Or (GetFileAttributes(possibleLocations()) & #PB_FileSystem_ExecUser))
      Protected NewList args.s()
      AddElement(args()) : args() = "-version"
      Protected ffprobeVerOutput.s = RunProgramNative(possibleLocations(),args())
      If ffprobeVerOutput
        Protected verRegExp = CreateRegularExpression(#PB_Any,"ffprobe version ([0-9.\-a-zA-Z]+) ")
        If ExamineRegularExpression(verRegExp,ffprobeVerOutput)
          While NextRegularExpressionMatch(verRegExp)
            ffprobeVer = RegularExpressionGroup(verRegExp,1)
          Wend
        EndIf
        FreeRegularExpression(verRegExp)
        If ffprobeVer = ""
          ffprobeVer = "unknown version"
        EndIf
        ffprobe = possibleLocations()
        Break
      EndIf
    EndIf
  Next
  ProcedureReturn ffprobe
EndProcedure

Procedure installffprobe()
  Shared dataDir.s
  Shared ffprobe.s
  Shared ffprobeVer.s
  Protected ev.i
  Protected size.i,part.i,download.i,progress.i,unpack.b
  Protected pack.i
  Enumeration
    #info
    #progress
    #legal
    #abort
  EndEnumeration
  
  size = getHTTPSize(#ffprobeURL)
  part = size/500
  download = ReceiveHTTPFile(#ffprobeURL,dataDir + "/ffprobe.zip",#PB_HTTP_Asynchronous,#myUserAgent)
  If part = 0 Or download = 0
    MessageRequester(#myName,#failedffprobeMsg,#PB_MessageRequester_Error)
    End
  EndIf
  
  OpenWindow(#wnd,0,0,400,115,#myName + " ffprobe installation",#PB_Window_Tool|#PB_Window_ScreenCentered)
  StickyWindow(#wnd,#True)
  TextGadget(#info,10,10,380,40,"Downloading the latest ffprobe from " + #ffprobeURL)
  ProgressBarGadget(#progress,10,50,380,20,0,500)
  ButtonGadget(#legal,160,80,150,25,"Legal information")
  ButtonGadget(#abort,310,80,80,25,"Abort")
  
  Repeat
    ev = WaitWindowEvent(100)
    If ev = #PB_Event_Gadget
      Select EventGadget()
        Case #legal
          RunProgram("open",#ffprobeLegal,"")
        Case #abort
          End
      EndSelect
    EndIf
    If download
      progress = HTTPProgress(download)
      Select progress
        Case #PB_HTTP_Success
          FinishHTTP(download)
          download = 0
          SetGadgetState(#progress,#PB_ProgressBar_Unknown)
          SetGadgetText(#info,"Installing ffprobe...")
          unpack = #True
        Case #PB_HTTP_Failed,#PB_HTTP_Aborted
          MessageRequester(#myName,#failedffprobeMsg,#PB_MessageRequester_Error)
        Default
          SetGadgetState(#progress,progress/part)
      EndSelect
    EndIf
    If unpack
      unpack = #False
      pack = OpenPack(#PB_Any,dataDir + "/ffprobe.zip",#PB_PackerPlugin_Zip)
      If pack
        If ExaminePack(pack)
          While NextPackEntry(pack)
            If PackEntryName(pack) = "ffprobe"
              If UncompressPackFile(pack,dataDir + "/ffprobe") > 0
                SetFileAttributes(dataDir + "/ffprobe",511) ; magic number to do chmod 777
                ffprobe = findffprobe()
                If ffprobe
                  debugLog("main","installed ffprobe " + ffprobeVer + " (" + ffprobe + ")")
                  ClosePack(pack)
                  DeleteFile(dataDir + "/ffprobe.zip",#PB_FileSystem_Force)
                  CloseWindow(#wnd)
                EndIf
                ProcedureReturn
              EndIf
            EndIf
          Wend
        EndIf
      EndIf
      MessageRequester(#myName,#failedffprobeMsg,#PB_MessageRequester_Error)
      End
    EndIf
  ForEver
EndProcedure

ProcedureC IsGroupRow(Object.I, Selector.I, TableView.I, Row.I)
  Protected Gadget, IsGroupRow.I
  
  Gadget = CocoaMessage(0, TableView, "tag")
  
  IsGroupRow = GetGadgetItemData(Gadget, Row)
  
  ProcedureReturn IsGroupRow
EndProcedure