Macro debugLog(type,message)
  Debug "[" + FormatDate("%dd.%mm.%yyyy %hh:%ii:%ss",Date()) + "] [" + UCase(type) + "] " + message
EndMacro

; taken from http://forums.purebasic.com/english/viewtopic.php?p=346952#p346952
Procedure.s replacestrin(st.s,vad.s,till.s)
  Protected a.l
  Protected final.s
  If FindString(st.s,vad.s,1)
    For a=1 To Len(st.s)
      If Mid(st.s,a,1)=vad.s
        final.s+till.s
      Else
        final.s+Mid(st.s,a,1)
      EndIf
    Next
    ProcedureReturn final.s
  Else
    ProcedureReturn st.s
  EndIf
EndProcedure

; taken from http://forums.purebasic.com/english/viewtopic.php?p=346952#p346952
Procedure.s URLEncode(st.s)
  st.s=URLEncoder(st.s)
  st.s=replacestrin(st.s,"&","%26")
  st.s=replacestrin(st.s,"!","%21")
  st.s=replacestrin(st.s,"*","%2A")
  st.s=replacestrin(st.s,"'","%27")
  st.s=replacestrin(st.s,"(","%28")
  st.s=replacestrin(st.s,")","%29")
  st.s=replacestrin(st.s,";","%3B")
  st.s=replacestrin(st.s,":","%3A")
  st.s=replacestrin(st.s,"@","%40")
  st.s=replacestrin(st.s,"&","%26")
  st.s=replacestrin(st.s,"=","%3D")
  st.s=replacestrin(st.s,"+","%2B")
  st.s=replacestrin(st.s,"$","%24")
  st.s=replacestrin(st.s,",","%2C")
  st.s=replacestrin(st.s,"/","%2F")
  st.s=replacestrin(st.s,"?","%3F")
  st.s=replacestrin(st.s,"#","%23")
  st.s=replacestrin(st.s,"[","%5B")
  st.s=replacestrin(st.s,"]","%5D")
  ProcedureReturn st.s
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
     path = "aac" Or
     path = "ac3" Or
     path = "wav" Or
     path = "aif" Or
     path = "aiff" Or
     path = "flac" Or
     path = "alac"
    ProcedureReturn #True
  EndIf
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

Macro cleanUp()
  debugLog("main","cleaning up")
  ClearGadgetItems(#playlist)
  ClearList(tagsToGet())
  ForEach tagsParserThreads()
    If IsThread(tagsParserThreads()) : KillThread(tagsParserThreads()) : EndIf
  Next
  ClearList(tagsParserThreads())
  If IsThread(playThread) : KillThread(playThread) : EndIf
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
EndMacro

Macro doPlay()
  debugLog("playback","playing start")
  RemoveWindowTimer(#wnd,0)
  If IsThread(playThread) : KillThread(playThread) : EndIf
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
  If nowPlaying\ID <> -1
    SetGadgetItemText(#playlist,nowPlaying\ID,"",#status)
  EndIf
  If AVAudioPlayer
    CocoaMessage(0,AVAudioPlayer,"stop")
    CocoaMessage(0,AVAudioPlayer,"dealloc")
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
  debugLog("playback","stopping")
  RemoveWindowTimer(#wnd,0)
  If nowPlaying\ID <> - 1
    SetGadgetItemText(#playlist,nowPlaying\ID,"",#status)
  EndIf
  If AVAudioPlayer
    CocoaMessage(0,AVAudioPlayer,"stop")
    CocoaMessage(0,AVAudioPlayer,"dealloc")
  EndIf
  ClearStructure(@nowPlaying,nowPlaying)
  nowPlaying\ID = -1
  If IsThread(playThread) : KillThread(playThread) : EndIf
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
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