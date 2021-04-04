Procedure lastfmScrobble(dummy)
  Shared lastfmSession
  Shared nowPlayingScrobble
  Shared lastfmNeedsScrobble
  Protected NewList args.s()
  Protected error.s
  Protected unixtimeUTC.s
  Protected api_sig.s
  Protected request.i
  
  AddElement(args()) : args() = "-u"
  AddElement(args()) : args() = "+%s"
  
  Repeat
    Delay(1000)
    If lastfmNeedsScrobble And lastfmSession
      debugLog("lastfm","scrobbling " + Str(nowPlayingScrobble\ID))
      unixtimeUTC = RunProgramNative("/bin/date",args())
      api_sig = StringFingerprint("api_key" + 
                                              #lastfmAPIKey + 
                                              "artist" + 
                                              nowPlayingScrobble\artist + 
                                              "duration" +
                                              Str(nowPlayingScrobble\durationSec) +
                                              "methodtrack.scrobblesk" + 
                                              lastfmSession +
                                              "timestamp" +
                                              unixtimeUTC +
                                              "track" + 
                                              nowPlayingScrobble\title + 
                                              #lastfmSecret,#PB_Cipher_MD5)
      request = HTTPRequest(#PB_HTTP_Post,#lastfmEndpoint + "/2.0/?format=json",
                            "method=track.scrobble&api_key=" + 
                            #lastfmAPIKey + 
                            "&artist=" +
                            URLEncode(nowPlayingScrobble\artist) +
                            "&track=" +
                            URLEncode(nowPlayingScrobble\title) +
                            "&duration=" +
                            Str(nowPlayingScrobble\durationSec) +
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
        If status <> "200"
          error = "scrobble failed with HTTP " + status + ~".\n" + HTTPInfo(request,#PB_HTTP_Response)
        Else
          If FindString(HTTPInfo(request,#PB_HTTP_Response),~"\"accepted\":1")
            lastfmNeedsScrobble = #False
            debugLog("lastfm","scrobbled")
          Else
            error = "scrobble failed with HTTP " + status + ~".\n" + HTTPInfo(request,#PB_HTTP_Response)
          EndIf
        EndIf
        FinishHTTP(request)
      Else
        debugLog("lastfm","failed to make a request")
      EndIf
      If error
        debugLog("lastfm",error)
      EndIf
    EndIf
  ForEver
EndProcedure

Procedure lastfmUpdateNowPlaying(dummy)
  Shared lastfmSession
  Shared nowPlayingUpdate
  Shared lastfmNeedsUpdate
  Protected error.s
  Protected api_sig.s
  Protected request.i
  Repeat
    Delay(1000)
    If lastfmNeedsUpdate
      debugLog("lastfm","updating nowplaying " + Str(nowPlayingUpdate\ID))
      api_sig = StringFingerprint("api_key" + 
                                  #lastfmAPIKey + 
                                  "artist" + 
                                  nowPlayingUpdate\artist + 
                                  "duration" +
                                  Str(nowPlayingUpdate\durationSec) +
                                  "methodtrack.updateNowPlayingsk" + 
                                  lastfmSession + 
                                  "track" + 
                                  nowPlayingUpdate\title + 
                                  #lastfmSecret,#PB_Cipher_MD5)
      request = HTTPRequest(#PB_HTTP_Post,#lastfmEndpoint + "/2.0/?format=json",
                            "method=track.updateNowPlaying&api_key=" + 
                            #lastfmAPIKey + 
                            "&artist=" +
                            URLEncode(nowPlayingUpdate\artist) +
                            "&track=" +
                            URLEncode(nowPlayingUpdate\title) +
                            "&duration=" +
                            Str(nowPlayingUpdate\durationSec) +
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
          error = "nowplaying update failed with HTTP " + status + ~".\n" + HTTPInfo(request,#PB_HTTP_Response)
        Else
          lastfmNeedsUpdate = #False
        EndIf
        FinishHTTP(request)
      EndIf
      If error
        debugLog("lastfm",error)
      EndIf
    EndIf
  ForEver
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

Procedure play(dummy)
  Protected AVAudioPlayer.i
  Shared nowPlaying
  Shared stopPlaying
  Protected NSPool.i = CocoaMessage(0,0,"NSAutoreleasePool new")
  Protected wasPaused.b
  Protected currentTimeSec.d
  Protected duration.d
  Protected durationInt.i
  Protected oldCurrent.i
  Protected newCurrent.i
  debugLog("playback",nowPlaying\path)
  AVAudioPlayer = CocoaMessage(0,CocoaMessage(0,0,"AVAudioPlayer alloc"),
                               "initWithContentsOfURL:",CocoaMessage(0,0,"NSURL fileURLWithPath:$",@nowPlaying\path),
                               "error:",#Null)
  If AVAudioPlayer
    CocoaMessage(@duration,AVAudioPlayer,"duration")
    durationInt = Int(Round(duration,#PB_Round_Nearest))
    If CocoaMessage(0,AVAudioPlayer,"play") = #YES
      PostEvent(#evPlayStart)
      Repeat
        If stopPlaying
          CocoaMessage(0,AVAudioPlayer,"dealloc")
          CocoaMessage(0,NSPool,"release")
          stopPlaying = #False
          ProcedureReturn
        EndIf
        If wasPaused <> nowPlaying\isPaused
          wasPaused = nowPlaying\isPaused
          If wasPaused
            CocoaMessage(0,AVAudioPlayer,"pause")
          Else
            CocoaMessage(0,AVAudioPlayer,"play")
          EndIf
        EndIf
        If CocoaMessage(0,AVAudioPlayer,"isPlaying") = #False And wasPaused = #False
          Break
        EndIf
        CocoaMessage(@currentTimeSec,AVAudioPlayer,"currentTime")
        newCurrent = Int(Round(currentTimeSec,#PB_Round_Down))
        If oldCurrent <> newCurrent
          oldCurrent = newCurrent
          PostEvent(#evUpdateNowPlaying,#wnd,0,newCurrent,duration)
        EndIf
        Delay(30)
      ForEver
    EndIf
    CocoaMessage(0,AVAudioPlayer,"dealloc")
  EndIf
  CocoaMessage(0,NSPool,"release")
  PostEvent(#evPlayFinish)
EndProcedure

Procedure lyrics(dummy)
  Shared nowPlaying,dataDir
  Protected lyricsHash.s = StringFingerprint(nowPlaying\artist + " - " + nowPlaying\title,#PB_Cipher_MD5)
  Protected NewList args.s()
  Protected json.s
  
  If FileSize(dataDir + "/lyrics/" + lyricsHash + ".txt") > 0
    nowPlaying\lyrics = ReadFileFast(dataDir + "/lyrics/" + lyricsHash + ".txt")
    debugLog ("lyrics","loaded from cache")
    PostEvent(#evLyricsSuccess)
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
    debugLog("lyrics","got from genius")
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
        PostEvent(#evLyricsSuccess)
        DeleteFile(dataDir + "/tmp/" + geniusPath,#PB_FileSystem_Force)
        ProcedureReturn
      Else
        debugLog("lyrics","failed to parse genius answer")
      EndIf
    EndIf
  EndIf
  PostEvent(#evLyricsFail)
EndProcedure

Procedure saveSettings()
  Shared dataDir.s
  Shared nowPlaying
  Shared lastfmSession.s,lastfmUser.s
  Protected json.i = CreateJSON(#PB_Any)
  Protected object.i = SetJSONObject(JSONValue(json))
  SetJSONInteger(AddJSONMember(object,"last_played_track_id"),nowPlaying\ID)
  SetJSONString(AddJSONMember(object,"lastfm_session"),lastfmSession)
  SetJSONString(AddJSONMember(object,"lastfm_user"),lastfmUser)
  WriteFileFast(dataDir + "/settings.json",ComposeJSON(json,#PB_JSON_PrettyPrint))
  FreeJSON(json)
  debugLog("main","settings saved")
EndProcedure

Procedure loadSettings()
  Shared dataDir.s
  Shared lastfmSession.s,lastfmUser.s
  Protected settingsData.s = ReadFileFast(dataDir + "/settings.json")
  Protected json.i = ParseJSON(#PB_Any,settingsData)
  Protected settings.settings
  If json
    ExtractJSONStructure(JSONValue(json),@settings,settings)
    FreeJSON(json)
    lastfmSession = settings\lastfm_session
    lastfmUser = settings\lastfm_user
    SetGadgetState(#playlist,settings\last_played_track_id)
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
      Next
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

Procedure nowPlayingHandler()
  Protected currentTime.i = EventType()
  Protected duration.i = EventData()
  Protected currentTimeFormatted.s
  Protected durationFormatted.s
  If duration > 3600
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
  MenuItem(#dockNext,"Next Track")
  MenuItem(#dockPrevious,"Previous Track")
  If nowPlaying\ID <> -1
    MenuItem(#dockStop,"Stop")
  EndIf
  ProcedureReturn CocoaMessage(0,MenuID(#dockMenu),"objectAtIndex:",0)
EndProcedure

Procedure.b isParsingCompleted()
  Shared tagsParserThreads()
  ForEach tagsParserThreads()
    If IsThread(tagsParserThreads())
      ProcedureReturn #False
    EndIf
  Next
  ProcedureReturn #True
EndProcedure