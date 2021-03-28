; taken here http://forums.purebasic.com/english/viewtopic.php?p=357702#p357702
Procedure RecursiveDirectorySafe(path$, List File.s())
   Protected NewList ToDo.s(), hd
   
   If Right(path$, 1) <> "/" : path$ + "/" : EndIf
   
   AddElement(ToDo())
   ToDo() = path$
   
   ResetList(ToDo())
   
   While NextElement(ToDo())
      path$ = ToDo()
      DeleteElement(ToDo())
      
      hd = ExamineDirectory(#PB_Any, path$, "*.*")
      
      If hd
         While NextDirectoryEntry(hd)
            
            If DirectoryEntryType(hd) = #PB_DirectoryEntry_File
               AddElement(File())
               File() = path$ + DirectoryEntryName(hd)
               
            Else
               If DirectoryEntryName(hd) <> "." And DirectoryEntryName(hd) <> ".."
                  ; ajout du répertoire
                  AddElement(ToDo())
                  ToDo() = path$ + DirectoryEntryName(hd) + "/"
                  
               EndIf
            EndIf
            
         Wend
         
         FinishDirectory(hd)
      EndIf
      
      ResetList(ToDo())
   Wend
   
EndProcedure

Procedure.s RunProgramNative(path.s,List args.s(),workdir.s = "",stdin.s = "")
  Protected i
  Protected arg.s
  Protected argsArray
  Protected stdout.s
  
  If FileSize(path) <= 0
    ProcedureReturn ""
  EndIf
  
  If ListSize(args())
    SelectElement(args(),0)
    arg = args()
    argsArray = CocoaMessage(0,0,"NSArray arrayWithObject:$",@arg)
    If ListSize(args()) > 1
      For i = 1 To ListSize(args()) - 1
        SelectElement(args(),i)
        arg = args()
        argsArray = CocoaMessage(0,argsArray,"arrayByAddingObject:$",@arg)
      Next
    EndIf
  EndIf
  Protected task = CocoaMessage(0,CocoaMessage(0,0,"NSTask alloc"),"init")
  
  CocoaMessage(0,task,"setLaunchPath:$",@path)
  
  If argsArray
    CocoaMessage(0,task,"setArguments:",argsArray)
  EndIf
  
  If workdir
    CocoaMessage(0,task,"setCurrentDirectoryPath:$",@workdir)
  EndIf
  
  If stdin
    Protected writePipe = CocoaMessage(0,0,"NSPipe pipe")
    Protected writeHandle = CocoaMessage(0,writePipe,"fileHandleForWriting")
    CocoaMessage(0,task,"setStandardInput:",writePipe)
    Protected string = CocoaMessage(0,0,"NSString stringWithString:$",@stdin)
    Protected stringData = CocoaMessage(0,string,"dataUsingEncoding:",#NSUTF8StringEncoding)
  EndIf
  
  Protected readPipe = CocoaMessage(0,0,"NSPipe pipe")
  Protected readHandle = CocoaMessage(0,readPipe,"fileHandleForReading")
  CocoaMessage(0,task,"setStandardOutput:",readPipe)
  
  CocoaMessage(0,task,"setStandardError:",CocoaMessage(0,task,"standardOutput"))
  
  CocoaMessage(0,task,"launch")
  
  If stdin
    CocoaMessage(0,writeHandle,"writeData:",stringData)
    CocoaMessage(0,writeHandle,"closeFile")
  EndIf
  
  Protected outputData = CocoaMessage(0,readHandle,"readDataToEndOfFile")
  If outputData
    Protected stdoutNative = CocoaMessage(0,CocoaMessage(0,0,"NSString alloc"),"initWithData:",outputData,"encoding:",#NSUTF8StringEncoding)
    stdout = PeekS(CocoaMessage(0,stdoutNative,"UTF8String"),-1,#PB_UTF8)
  EndIf
  
  CocoaMessage(0,task,"release")
  
  ProcedureReturn stdout
EndProcedure

Procedure.b isSupportedFile(path.s)
  path = LCase(GetExtensionPart(path))
  If path = "mp3" Or
     path = "m4a" Or
     path = "ogg" Or
     path = "oga" Or
     path = "flac" Or
     path = "alac" Or
     path = "ape" Or
     path = "wma"
    ProcedureReturn #True
  EndIf
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

Procedure.s ReadFileFast(path.s)
  Protected file = ReadFile(#PB_Any,path)
  Protected string.s
  If file
    string = ReadString(file,#PB_File_IgnoreEOL)
    CloseFile(file)
  EndIf
  ProcedureReturn string
EndProcedure

Procedure WriteFileFast(path.s,string.s)
  Protected file = CreateFile(#PB_Any,path)
  If file
    WriteString(file,string)
    CloseFile(file)
    ProcedureReturn #True
  EndIf
  ProcedureReturn #False
EndProcedure

Procedure lastfmScrobble(*nowPlaying.nowPlaying)
  Debug "lastfm: scrobbling"
  Shared lastfmSession
  Protected NewList args.s()
  AddElement(args()) : args() = "-u"
  AddElement(args()) : args() = "+%s"
  Protected unixtimeUTC.s = RunProgramNative("/bin/date",args())
  Protected api_sig.s = StringFingerprint("api_key" + 
                                          #lastfmAPIKey + 
                                          "artist" + 
                                          *nowPlaying\artist + 
                                          "duration" +
                                          Str(*nowPlaying\durationSec) +
                                          "methodtrack.scrobblesk" + 
                                          lastfmSession +
                                          "timestamp" +
                                          unixtimeUTC +
                                          "track" + 
                                          *nowPlaying\title + 
                                          #lastfmSecret,#PB_Cipher_MD5)
  Protected request = HTTPRequest(#PB_HTTP_Post,#lastfmEndpoint + "/2.0/?format=json",
                                  "method=track.scrobble&api_key=" + 
                                  #lastfmAPIKey + 
                                  "&artist=" +
                                  *nowPlaying\artist +
                                  "&track=" +
                                  *nowPlaying\title +
                                  "&duration=" +
                                  Str(*nowPlaying\durationSec) +
                                  "&timestamp=" +
                                  unixtimeUTC +
                                  "&sk=" +
                                  lastfmSession +
                                  "&api_sig=" + api_sig)
  If request
    Protected status.s = HTTPInfo(request,#PB_HTTP_StatusCode)
    If status <> "200"
      Protected error.s = "Last.fm scrobble failed with HTTP " + status + ~".\n" + HTTPInfo(request,#PB_HTTP_Response)
      Debug error
    EndIf
    FinishHTTP(request)
  EndIf
EndProcedure

Procedure lastfmUpdateNowPlaying(*nowPlaying.nowPlaying)
  Debug "lastfm: updating nowplaying"
  Shared lastfmSession
  Protected api_sig.s = StringFingerprint("api_key" + 
                                          #lastfmAPIKey + 
                                          "artist" + 
                                          *nowPlaying\artist + 
                                          "duration" +
                                          Str(*nowPlaying\durationSec) +
                                          "methodtrack.updateNowPlayingsk" + 
                                          lastfmSession + 
                                          "track" + 
                                          *nowPlaying\title + 
                                          #lastfmSecret,#PB_Cipher_MD5)
  Protected request = HTTPRequest(#PB_HTTP_Post,#lastfmEndpoint + "/2.0/?format=json",
                                  "method=track.updateNowPlaying&api_key=" + 
                                  #lastfmAPIKey + 
                                  "&artist=" +
                                  *nowPlaying\artist +
                                  "&track=" +
                                  *nowPlaying\title +
                                  "&duration=" +
                                  Str(*nowPlaying\durationSec) +
                                  "&sk=" +
                                  lastfmSession +
                                  "&api_sig=" + api_sig)
  If request
    Protected status.s = HTTPInfo(request,#PB_HTTP_StatusCode)
    If status <> "200"
      Protected error.s = "Last.fm nowplaying update failed with HTTP " + status + ~".\n" + HTTPInfo(request,#PB_HTTP_Response)
      Debug error
    EndIf
    FinishHTTP(request)
  EndIf
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
  Shared playPID.i
  Shared nowPlaying
  If IsProgram(playPID)
    KillProgram(playPID)
    CloseProgram(playPID)
  EndIf
  playPID = RunProgram("/usr/local/bin/ffplay",~"-vn -nodisp -autoexit \"" + nowPlaying\path + ~"\"","",#PB_Program_Open)
  PostEvent(#evPlayStart)
  WaitProgram(playPID)
  CloseProgram(playPID)
  ;Delay(10000)
  PostEvent(#evPlayFinish)
EndProcedure

Procedure lyrics(dummy)
  Shared nowPlaying,dataDir
  Protected lyricsHash.s = StringFingerprint(nowPlaying\artist + " - " + nowPlaying\title,#PB_Cipher_MD5)
  Protected NewList args.s()
  Protected json.s
  
  If FileSize(dataDir + "/lyrics/" + lyricsHash + ".txt") > 0
    nowPlaying\lyrics = ReadFileFast(dataDir + "/lyrics/" + lyricsHash + ".txt")
    ;Debug "loaded lyrics from cache"
    PostEvent(#evLyricsSuccess)
    ProcedureReturn
  EndIf
  
  ;AddElement(args()) : args() = "-u"
  ;AddElement(args()) : args() = "-v"
  ;AddElement(args()) : args() = ~"-c 'prisdfnt(\"hi\")'"
  ;AddElement(args()) : args() = ~""
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
        PostEvent(#evLyricsSuccess)
        DeleteFile(dataDir + "/tmp/" + geniusPath,#PB_FileSystem_Force)
        ProcedureReturn
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
  
  If nowPlaying\albumArt <> albumArt
    If albumArt
      If IsImage(#currentAlbumArt) : FreeImage(#currentAlbumArt) : EndIf
      LoadImage(#currentAlbumArt,albumArt)
      ResizeImage(#currentAlbumArt,500,500,#PB_Image_Smooth)
      SetGadgetState(#albumArt,ImageID(#currentAlbumArt))
    Else
      SetGadgetState(#albumArt,ImageID(#defaultAlbumArt))
    EndIf
    nowPlaying\albumArt = albumArt
  ;Else
  ;  Debug "image is the same"
  EndIf
EndProcedure

Procedure nowPlayingHandler()
  Shared nowPlaying
  Protected currentTimeSec.i = (ElapsedMilliseconds() - nowPlaying\startedAt) / 1000
  Protected currentTime.s
  If nowPlaying\durationSec > 3600
    currentTime = FormatDate("%hh:%ii:%ss",currentTimeSec)
  Else
    currentTime = FormatDate("%ii:%ss",currentTimeSec)
  EndIf
  SetGadgetText(#nowPlayingDuration,currentTime + " / " + nowPlaying\duration)
  Protected part.f = nowPlaying\durationSec / 100
  If part > 0
    SetGadgetState(#nowPlayingProgress,currentTimeSec / part)
  EndIf
  SetGadgetData(#nowPlayingProgress,currentTimeSec)
EndProcedure

ProcedureC dockMenuHandler(object.i,selector.i,sender.i)
  Shared nowPlaying
  If IsMenu(#dockMenu) : FreeMenu(#dockMenu) : EndIf
  CreateMenu(#dockMenu,0)
  MenuTitle("")
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

Macro cleanUp()
  ClearGadgetItems(#playlist)
  ClearList(tagsToGet())
  ForEach tagsParserThreads()
    If IsThread(tagsParserThreads()) : KillThread(tagsParserThreads()) : EndIf
  Next
  ClearList(tagsParserThreads())
  If IsThread(playThread) : KillThread(playThread) : EndIf
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
  If IsProgram(playPID)
    KillProgram(playPID)
    CloseProgram(playPID)
  EndIf
EndMacro

Macro doPlay()
  If IsProgram(playPID)
    KillProgram(playPID)
    CloseProgram(playPID)
  EndIf
  If IsThread(playThread) : KillThread(playThread) : EndIf
  If nowPlaying\ID <> -1
    SetGadgetItemText(#playlist,nowPlaying\ID,"",#status)
  EndIf
  nowPlaying\ID = GetGadgetState(#playlist)
  nowPlaying\path = GetGadgetItemText(#playlist,nowPlaying\ID,#file)
  nowPlaying\artist = GetGadgetItemText(#playlist,nowPlaying\ID,#artist)
  nowPlaying\title = GetGadgetItemText(#playlist,nowPlaying\ID,#title)
  nowPlaying\album = GetGadgetItemText(#playlist,nowPlaying\ID,#album)
  nowPlaying\duration = GetGadgetItemText(#playlist,nowPlaying\ID,#duration)
  If Len(nowPlaying\duration) > 5
    nowPlaying\durationSec = ParseDate("%hh:%ii:%ss",nowPlaying\duration)
  Else
    nowPlaying\durationSec = ParseDate("%ii:%ss",nowPlaying\duration)
  EndIf
  nowPlaying\details = GetGadgetItemText(#playlist,nowPlaying\ID,#details)
  nowPlaying\lyrics = ""
  nowPlaying\isPaused = #False
  playThread = CreateThread(@play(),0)
  SetGadgetText(#toolbarPlayPause,#pauseSymbol)
  SetGadgetItemText(#playlist,nowPlaying\ID,#playSymbol,#status)
  SetWindowTitle(#wnd,nowPlaying\artist +" - " + nowPlaying\title + " (" + nowPlaying\duration + ")" + " • " + #myName)
  SetGadgetText(#lyrics,"[looking for lyrics...]")
  SetGadgetText(#nowPlaying,nowPlaying\artist + " - " + nowPlaying\title + ~"\n" + nowPlaying\album + ~"\n" + nowPlaying\details)
  If nowPlaying\durationSec > 3600
    SetGadgetText(#nowPlayingDuration,"00:00:00 / " + nowPlaying\duration)
  Else
    SetGadgetText(#nowPlayingDuration,"00:00 / " + nowPlaying\duration)
  EndIf
  SetGadgetState(#nowPlayingProgress,0)
  lyricsThread = CreateThread(@lyrics(),0)
  loadAlbumArt()
EndMacro

Macro doStop()
  RemoveWindowTimer(#wnd,0)
  If nowPlaying\ID <> - 1
    SetGadgetItemText(#playlist,nowPlaying\ID,"",#status)
  EndIf
  ClearStructure(@nowPlaying,nowPlaying)
  nowPlaying\ID = -1
  If IsThread(playThread) : KillThread(playThread) : EndIf
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
  If IsProgram(playPID)
    KillProgram(playPID)
    CloseProgram(playPID)
  EndIf
  SetGadgetText(#toolbarPlayPause,#playSymbol)
  SetWindowTitle(#wnd,#myName)
  SetGadgetText(#nowPlaying,"")
  SetGadgetText(#nowPlayingDuration,"[standby]")
  SetGadgetState(#nowPlayingProgress,0)
  SetGadgetText(#lyrics,"")
  loadAlbumArt()
EndMacro

Macro doTags()
  If ListSize(tagsToGet())
    If ListSize(tagsToGet()) < systemThreads
      numThreads = ListSize(tagsToGet())
    Else
      numThreads = systemThreads
    EndIf
    For j = 0 To numThreads - 1
      AddElement(tagsParserThreads())
      tagsParserThreads() = CreateThread(@getTags(),j)
    Next
  EndIf
EndMacro

Macro updateLastfmStatus()
  If lastfmSession
    SetMenuItemText(#menu,#lastfmState,"Log out of Last.fm")
  Else
    SetMenuItemText(#menu,#lastfmState,"Log in to Last.fm")
  EndIf
  If lastfmUser
    SetMenuItemText(#menu,#lastfmUser,lastfmUser)
    DisableMenuItem(#menu,#lastfmUser,#False)
  Else
    SetMenuItemText(#menu,#lastfmUser,"Not logged in")
    DisableMenuItem(#menu,#lastfmUser,#False)
  EndIf
EndMacro