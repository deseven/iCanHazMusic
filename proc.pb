Procedure lastfmScrobble(dummy)
  Shared nowPlaying
  Shared lastfmLock
  Protected nowPlayingSafe.nowPlaying
  LockMutex(lastfmLock)
  CopyStructure(@nowPlaying,@nowPlayingSafe,nowPlaying)
  
  Shared lastfmSession
  Shared lastfmScrobbleError.s
  Protected error.s
  Protected unixtimeUTC.s
  Protected api_sig.s
  Protected request.i
  
  unixtimeUTC = Str(unixtimeUTC())
  api_sig = StringFingerprint("api_key" + 
                              #lastfmAPIKey + 
                              "artist" + 
                              nowPlayingSafe\artist + 
                              "duration" +
                              Str(nowPlayingSafe\durationSec) +
                              "methodtrack.scrobblesk" + 
                              lastfmSession +
                              "timestamp" +
                              unixtimeUTC +
                              "track" + 
                              nowPlayingSafe\title + 
                              #lastfmSecret,#PB_Cipher_MD5)
  request = HTTPRequest(#PB_HTTP_Post,#lastfmEndpoint + "/2.0/?format=json",
                        "method=track.scrobble&api_key=" + 
                        #lastfmAPIKey + 
                        "&artist=" +
                        URLEncode(nowPlayingSafe\artist) +
                        "&track=" +
                        URLEncode(nowPlayingSafe\title) +
                        "&duration=" +
                        Str(nowPlayingSafe\durationSec) +
                        "&timestamp=" +
                        unixtimeUTC +
                        "&sk=" +
                        lastfmSession +
                        "&api_sig=" + api_sig,#PB_HTTP_Asynchronous)
  If request
    Protected startTime.i = ElapsedMilliseconds()
    While HTTPProgress(request) >= 0
      Delay(50)
      If ElapsedMilliseconds() > startTime + 10000
        AbortHTTP(request)
      EndIf
    Wend
    Protected status.s = HTTPInfo(request,#PB_HTTP_StatusCode)
    Protected response.s = HTTPInfo(request,#PB_HTTP_Response)
    If status <> "200"
      error = "scrobble failed with HTTP " + status + ~".\n" + response
    Else
      If FindString(response,~"\"accepted\":1")
        PostEvent(#evLastfmScrobbleSuccess,0,0,0,nowPlayingSafe\ID)
      ElseIf FindString(response,~"\"ignored\":1")
        error = "ignored " + Str(nowPlayingSafe\ID) + ~" with\n" + response
      Else
        error = "scrobble " + Str(nowPlayingSafe\ID) + " failed with HTTP " + status + ~".\n" + response
      EndIf
    EndIf
    FinishHTTP(request)
  Else
    error = "failed To make a request"
  EndIf
  If error
    lastfmScrobbleError = error
    PostEvent(#evLastfmScrobbleError)
  EndIf
  UnlockMutex(lastfmLock)
EndProcedure

Procedure lastfmUpdateNowPlaying(dummy)
  Shared nowPlaying
  Shared lastfmLock
  Protected nowPlayingSafe.nowPlaying
  LockMutex(lastfmLock)
  CopyStructure(@nowPlaying,@nowPlayingSafe,nowPlaying)
  
  Shared lastfmSession
  Shared lastfmUpdateError.s
  Protected error.s
  Protected api_sig.s
  Protected request.i
  api_sig = StringFingerprint("api_key" + 
                              #lastfmAPIKey + 
                              "artist" + 
                              nowPlayingSafe\artist + 
                              "duration" +
                              Str(nowPlayingSafe\durationSec) +
                              "methodtrack.updateNowPlayingsk" + 
                              lastfmSession + 
                              "track" + 
                              nowPlayingSafe\title + 
                              #lastfmSecret,#PB_Cipher_MD5)
  request = HTTPRequest(#PB_HTTP_Post,#lastfmEndpoint + "/2.0/?format=json",
                        "method=track.updateNowPlaying&api_key=" + 
                        #lastfmAPIKey + 
                        "&artist=" +
                        URLEncode(nowPlayingSafe\artist) +
                        "&track=" +
                        URLEncode(nowPlayingSafe\title) +
                        "&duration=" +
                        Str(nowPlayingSafe\durationSec) +
                        "&sk=" +
                        lastfmSession +
                        "&api_sig=" + api_sig,#PB_HTTP_Asynchronous)
  If request
    Protected startTime.i = ElapsedMilliseconds()
    While HTTPProgress(request) >= 0
      Delay(50)
      If ElapsedMilliseconds() > startTime + 10000
        AbortHTTP(request)
      EndIf
    Wend
    Protected status.s = HTTPInfo(request,#PB_HTTP_StatusCode)
    If status <> "200"
      error = "nowplaying update " + Str(nowPlayingSafe\ID) + " failed with HTTP " + status + ~".\n" + HTTPInfo(request,#PB_HTTP_Response)
    Else
      PostEvent(#evLastfmUpdateSuccess,0,0,0,nowPlayingSafe\ID)
    EndIf
    FinishHTTP(request)
  EndIf
  If error
    lastfmUpdateError = error
    PostEvent(#evLastfmUpdateError)
  EndIf
  UnlockMutex(lastfmLock)
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
    
    json = RunProgramNative("/usr/local/bin/ffprobe",args())
    
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

Procedure lyrics(dummy)
  Shared nowPlaying,dataDir
  Protected lyricsHash.s = StringFingerprint(nowPlaying\artist + " - " + nowPlaying\title,#PB_Cipher_MD5)
  Protected NewList args.s()
  Protected json.s
  
  If FileSize(dataDir + "/lyrics/" + lyricsHash + ".txt") > 0
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

Procedure saveSettings()
  Shared dataDir.s
  Shared lastfmSession.s,lastfmUser.s
  Shared lastPlayedID
  Protected json.i = CreateJSON(#PB_Any)
  Protected object.i = SetJSONObject(JSONValue(json))
  SetJSONInteger(AddJSONMember(object,"last_played_track_id"),lastPlayedID)
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
  WriteFileFast(dataDir + "/settings.json",ComposeJSON(json,#PB_JSON_PrettyPrint))
  ;Debug ComposeJSON(json,#PB_JSON_PrettyPrint)
  FreeJSON(json)
  debugLog("main","settings saved")
EndProcedure

Procedure loadSettings()
  Shared dataDir.s
  Shared lastfmSession.s,lastfmUser.s
  Shared lastPlayedID
  Protected settingsData.s = ReadFileFast(dataDir + "/settings.json")
  Protected json.i = ParseJSON(#PB_Any,settingsData)
  Protected settings.settings
  If json
    ExtractJSONStructure(JSONValue(json),@settings,settings)
    FreeJSON(json)
    lastfmSession = settings\lastfm\session
    lastfmUser = settings\lastfm\user
    lastPlayedID = settings\last_played_track_id
    SetGadgetState(#playlist,settings\last_played_track_id)
    If settings\window\x And settings\window\y And settings\window\width And settings\window\height
      ResizeWindow(#wnd,settings\window\x,settings\window\y,settings\window\width,settings\window\height)
    EndIf
    If settings\window\fullscreen
      EnterWindowFullscreen(#wnd)
    EndIf
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
  Protected id.i
  If ListSize(playQueue())
    SelectElement(playQueue(),0)
    id = playQueue()
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

ProcedureC IsGroupRow(Object.I, Selector.I, TableView.I, Row.I)
  Protected Gadget, IsGroupRow.I
  
  Gadget = CocoaMessage(0, TableView, "tag")
  
  IsGroupRow = GetGadgetItemData(Gadget, Row)
  
  ProcedureReturn IsGroupRow
EndProcedure