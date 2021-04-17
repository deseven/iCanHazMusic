Macro debugLog(type,message)
  Debug "[" + FormatDate("%dd.%mm.%yyyy %hh:%ii:%ss",Date()) + "] [" + UCase(type) + "] " + message
EndMacro

; taken from http://forums.purebasic.com/english/viewtopic.php?p=346952#p346952
Procedure.s URLEncode(st.s)
  st=URLEncoder(st)
  st=ReplaceString(st,"&","%26")
  st=ReplaceString(st,"!","%21")
  st=ReplaceString(st,"*","%2A")
  st=ReplaceString(st,"'","%27")
  st=ReplaceString(st,"(","%28")
  st=ReplaceString(st,")","%29")
  st=ReplaceString(st,";","%3B")
  st=ReplaceString(st,":","%3A")
  st=ReplaceString(st,"@","%40")
  st=ReplaceString(st,"&","%26")
  st=ReplaceString(st,"=","%3D")
  st=ReplaceString(st,"+","%2B")
  st=ReplaceString(st,"$","%24")
  st=ReplaceString(st,",","%2C")
  st=ReplaceString(st,"/","%2F")
  st=ReplaceString(st,"?","%3F")
  st=ReplaceString(st,"#","%23")
  st=ReplaceString(st,"[","%5B")
  st=ReplaceString(st,"]","%5D")
  ProcedureReturn st
EndProcedure

; taken from http://forums.purebasic.com/english/viewtopic.php?p=357702#p357702
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
  
  If Not _IsMainScope
    Protected Pool = CocoaMessage(0, 0, "NSAutoreleasePool new")
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
  
  If Pool
    CocoaMessage(0, Pool, "release")
  EndIf
  
  ProcedureReturn stdout
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

Procedure DelayEvent(event.i)
  Delay(3000)
  PostEvent(event)
EndProcedure

Macro cleanUp()
  debugLog("main","cleaning up")
  EXIT = #True
  ForEach tagsParserThreads()
    WaitThread(tagsParserThreads())
  Next
  EXIT = #False
  ClearGadgetItems(#playlist)
  ClearList(tagsToGet())
  ClearList(tagsParserThreads())
  FreeMutex(tagsToGetLock)
  tagsToGetLock = CreateMutex()  
EndMacro

Macro die()
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
  If IsThread(lastfmUpdateNowPlayingThread) : KillThread(lastfmUpdateNowPlayingThread) : EndIf
  If IsThread(lastfmScrobbleThread) : KillThread(lastfmScrobbleThread) : EndIf
  ForEach tagsParserThreads()
    If IsThread(tagsParserThreads()) : KillThread(tagsParserThreads()) : EndIf
  Next
EndMacro

Macro doPlay()
  debugLog("playback","play")
  If audioplayer::getPlayer()
    audioplayer::stop()
  EndIf
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
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
  SetGadgetText(#toolbarPlayPause,#pauseSymbol)
  SetGadgetItemText(#playlist,nowPlaying\ID,#playSymbol,#status)
  SetWindowTitle(#wnd,nowPlaying\artist +" - " + nowPlaying\title + " (" + nowPlaying\duration + ")" + " • " + #myName)
  SetGadgetText(#lyrics,"[looking for lyrics...]")
  SetGadgetText(#nowPlaying,nowPlaying\artist + " - " + nowPlaying\title + ~"\n" + nowPlaying\album + ~"\n" + nowPlaying\details)
  If nowPlaying\durationSec >= 3600
    SetGadgetText(#nowPlayingDuration,"00:00:00 / " + nowPlaying\duration)
  Else
    SetGadgetText(#nowPlayingDuration,"00:00 / " + nowPlaying\duration)
  EndIf
  audioplayer::load(nowPlaying\path)
  Select audioplayer::getPlayer()
    Case audioplayer::#AVAudioPlayer
      CocoaMessage(0,audioplayer::getPlayerID(),"setDelegate:",AVPdelegate)
      If timeoutTime <> #defaultTimeout
        timeoutTime = #defaultTimeout
        debugLog("main","switching to default events timeout")
      EndIf
    Case audioplayer::#PBSoundLibrary
      If timeoutTime <> #fastTimeout
        timeoutTime = #fastTimeout
        debugLog("main","switching to fast events timeout")
      EndIf
      fastTimeoutsRoutine = #True
  EndSelect
  audioplayer::play()
  nowPlaying\durationSec = audioplayer::getDuration()/1000
  SetGadgetState(#nowPlayingProgress,0)
  lyricsThread = CreateThread(@lyrics(),0)
  loadAlbumArt()
  PostEvent(#evPlayStart)
EndMacro

Macro doStop()
  debugLog("playback","stop")
  If audioplayer::getPlayer()
    audioplayer::stop()
  EndIf
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
  If nowPlaying\ID <> -1
    SetGadgetItemText(#playlist,nowPlaying\ID,"",#status)
  EndIf
  ClearStructure(@nowPlaying,nowPlaying)
  nowPlaying\ID = -1
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