Macro debugLog(type,message)
  Define logMessage.s = "[" + UCase(type) + "] " + message
  If #PB_Compiler_Debugger
    Debug "[" + FormatDate("%dd.%mm.%yyyy %hh:%ii:%ss",Date()) + "] " + logMessage
  EndIf
  NSLog(logMessage)
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
    Protected Pool = CocoaMessage(0,0,"NSAutoreleasePool new")
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
  CocoaMessage(0,readHandle,"closeFile")
  If outputData
    Protected stdoutNative = CocoaMessage(0,CocoaMessage(0,0,"NSString alloc"),"initWithData:",outputData,"encoding:",#NSUTF8StringEncoding)
    stdout = PeekS(CocoaMessage(0,stdoutNative,"UTF8String"),-1,#PB_UTF8)
  EndIf
  
  CocoaMessage(0,task,"release")
  
  If Pool
    CocoaMessage(0,Pool,"release")
  EndIf
  
  ProcedureReturn stdout
EndProcedure

Procedure.i unixtimeUTC()
  If Not _IsMainScope
    Protected Pool = CocoaMessage(0,0,"NSAutoreleasePool new")
  EndIf
  
  Protected NSDate = CocoaMessage(0,0,"NSDate date")
  Protected NSTimeInterval.d
  CocoaMessage(@NSTimeInterval,NSDate,"timeIntervalSince1970")
  CocoaMessage(0,NSDate,"dealloc")
  
  If Pool
    CocoaMessage(0,Pool,"release")
  EndIf
  
  ProcedureReturn NSTimeInterval
EndProcedure

; based on wilbert's code (http://www.purebasic.fr/english/viewtopic.php?p=469232#p469232)
Procedure ListIconGadgetHideColumn(gadget.i,index.i,state.b)
  Protected column = CocoaMessage(0,CocoaMessage(0,GadgetID(gadget),"tableColumns"),"objectAtIndex:",index)
  If column
    If state
      CocoaMessage(0,column,"setHidden:",#YES)
    Else
      CocoaMessage(0,column,"setHidden:",#NO)
    EndIf
  EndIf
EndProcedure

; code by Shardik (http://www.purebasic.fr/english/viewtopic.php?p=393256#p393256)
Procedure SetListIconColumnJustification(ListIconID.I,ColumnIndex.I,Alignment.I)
  Protected ColumnHeaderCell.I
  Protected ColumnObject.I
  Protected ColumnObjectArray.I

  ; ----- Justify text of column cells
  CocoaMessage(@ColumnObjectArray, GadgetID(ListIconID), "tableColumns")
  CocoaMessage(@ColumnObject, ColumnObjectArray, "objectAtIndex:", ColumnIndex)
  CocoaMessage(0, CocoaMessage(0, ColumnObject, "dataCell"), "setAlignment:", Alignment)

  ; ----- Justify text of column header
  CocoaMessage(@ColumnHeaderCell, ColumnObject, "headerCell")
  CocoaMessage(0, ColumnHeaderCell, "setAlignment:", Alignment)

  ; ----- Redraw ListIcon contents to see change
  CocoaMessage(0, GadgetID(ListIconID), "reloadData")
EndProcedure

Procedure IsWindowFullscreen(window)
  #NSFullScreenWindowMask = 1 << 14
  ProcedureReturn Bool( CocoaMessage(0, WindowID(window), "styleMask") & #NSFullScreenWindowMask )
EndProcedure

Procedure EnterWindowFullscreen(window)
  CocoaMessage(0, WindowID(window), "enterFullScreenMode:")
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

Procedure ReadBinaryFileFast(path.s,*data)
  Protected file = ReadFile(#PB_Any,path)
  If file
    If MemorySize(*data) >= Lof(file)
      ReadData(file,*data,Lof(file))
      CloseFile(file)
      ProcedureReturn #True
    Else
      CloseFile(file)
    EndIf
  EndIf
EndProcedure

Procedure WriteFileFast(path.s,string.s)
  Protected file = CreateFile(#PB_Any,path)
  If file
    WriteString(file,string)
    CloseFile(file)
    ProcedureReturn #True
  EndIf
EndProcedure

Procedure DelayEvent(event.i)
  Delay(1000)
  PostEvent(event)
EndProcedure

ImportC ""
  NSLog2(Format, Arg) As "_NSLog"
EndImport

Procedure NSLog(Message.s)
  Static Format.i
  If Format = 0
    CompilerIf #PB_Compiler_Unicode
      Format = CocoaMessage(0, 0, "NSString stringWithString:$", @"%S")
    CompilerElse
      Format = CocoaMessage(0, 0, "NSString stringWithString:$", @"%s")
    CompilerEndIf  
    CocoaMessage(0, Format, "retain")
  EndIf
  NSLog2(Format, @Message)  
EndProcedure

Procedure isPortAvailable(port.l,flags = 0)
  If Not flags
    flags = #PB_Network_TCP|#PB_Network_IPv4
  EndIf
  Protected server.i = CreateNetworkServer(#PB_Any,port,flags)
  If server
    CloseNetworkServer(server)
    ProcedureReturn #True
  EndIf
EndProcedure

; Author : Danilo
; Date   : 25.03.2014
; Link   : https://www.purebasic.fr/english/viewtopic.php?f=19&t=58828
; Info   : NSActivityOptions is a 64bit typedef - use it with quads (.q) !!!

#NSActivityIdleDisplaySleepDisabled             = 1 << 40
#NSActivityIdleSystemSleepDisabled              = 1 << 20
#NSActivitySuddenTerminationDisabled            = (1 << 14)
#NSActivityAutomaticTerminationDisabled         = (1 << 15)
#NSActivityUserInitiated                        = ($00FFFFFF | #NSActivityIdleSystemSleepDisabled)
#NSActivityUserInitiatedAllowingIdleSystemSleep = (#NSActivityUserInitiated & ~#NSActivityIdleSystemSleepDisabled)
#NSActivityBackground                           = $000000FF
#NSActivityLatencyCritical                      = $FF00000000

Procedure BeginWork(Option.q, Reason.s= "MyReason")
  Protected NSProcessInfo = CocoaMessage(0,0,"NSProcessInfo processInfo")
  If NSProcessInfo
    ProcedureReturn CocoaMessage(0, NSProcessInfo, "beginActivityWithOptions:@", @Option, "reason:$", @Reason)
  EndIf
EndProcedure

Procedure EndWork(Activity)
  Protected NSProcessInfo = CocoaMessage(0, 0, "NSProcessInfo processInfo")
  If NSProcessInfo
    CocoaMessage(0, NSProcessInfo, "endActivity:", Activity)
  EndIf
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
  doStop()
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
  If IsThread(webThread)
    debugLog("web","stopping web server")
    webStop = #True
    WaitThread(webThread,3000)
    If IsThread(webThread) : KillThread(webThread) : EndIf
    debugLog("web","web server stopped")
  EndIf
  ForEach tagsParserThreads()
    If IsThread(tagsParserThreads()) : KillThread(tagsParserThreads()) : EndIf
  Next
  If FileSize(dataDir + "/ffprobe.zip") > 0
    DeleteFile(dataDir + "/ffprobe.zip",#PB_FileSystem_Force)
  EndIf
EndMacro

Macro doPlay()
  If audioplayer::getPlayerID()
    audioplayer::free()
  EndIf
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
  If nowPlaying\ID <> -1
    SetGadgetItemText(#playlist,nowPlaying\ID,"",#status)
  EndIf
  nowPlaying\ID = nextID
  nowPlaying\path = GetGadgetItemText(#playlist,nowPlaying\ID,#file)
  nowPlaying\artist = GetGadgetItemText(#playlist,nowPlaying\ID,#artist)
  nowPlaying\title = GetGadgetItemText(#playlist,nowPlaying\ID,#title)
  nowPlaying\album = GetGadgetItemText(#playlist,nowPlaying\ID,#album)
  nowPlaying\duration = GetGadgetItemText(#playlist,nowPlaying\ID,#duration)
  debugLog("playback","loading " + nowPlaying\path)
  If Len(nowPlaying\duration) > 5
    nowPlaying\durationSec = ParseDate("%hh:%ii:%ss",nowPlaying\duration)
  Else
    nowPlaying\durationSec = ParseDate("%ii:%ss",nowPlaying\duration)
  EndIf
  nowPlaying\details = GetGadgetItemText(#playlist,nowPlaying\ID,#details)
  nowPlaying\lyrics = ""
  nowPlaying\isPaused = #False
  lastPlayedID = nowPlaying\ID
  SetGadgetText(#toolbarPlayPause,#pauseSymbol)
  SetGadgetItemText(#playlist,nowPlaying\ID,#playSymbol,#status)
  SetWindowTitle(#wnd,nowPlaying\artist +" - " + nowPlaying\title + " (" + nowPlaying\duration + ")" + " • " + #myNameVer)
  SetGadgetText(#nowPlaying,nowPlaying\artist + " - " + nowPlaying\title + ~"\n" + nowPlaying\album + ~"\n" + nowPlaying\details)
  If nowPlaying\durationSec >= 3600
    SetGadgetText(#nowPlayingDuration,"00:00:00 / " + nowPlaying\duration)
  Else
    SetGadgetText(#nowPlayingDuration,"00:00 / " + nowPlaying\duration)
  EndIf
  audioplayer::load(nowPlaying\path)
  audioplayer::setFinishEvent(#evPlayFinish)
  audioplayer::play()
  nowPlaying\durationSec = audioplayer::getDuration()/1000
  SetGadgetState(#nowPlayingProgress,0)
  If lyricsAvailable
    HideGadget(#toolbarLyricsReloadWeb,#True)
    SetGadgetText(#lyrics,"[looking for lyrics...]")
    lyricsThread = CreateThread(@lyrics(),#False)
  EndIf
  loadAlbumArt()
  LastElement(history()) : AddElement(history()) : history() = nowPlaying\ID
  If ListSize(history()) > 1000
    FirstElement(history())
    DeleteElement(history())
  EndIf
  If audioplayer::getTempPath()
    debugLog("playback","playing (ffmpeg)")
  Else
    debugLog("playback","playing (native)")
  EndIf
  PostEvent(#evPlayStart)
EndMacro

Macro doStop()
  debugLog("playback","stop")
  If audioplayer::getPlayerID()
    audioplayer::free()
  EndIf
  If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
  If nowPlaying\ID <> -1
    SetGadgetItemText(#playlist,nowPlaying\ID,"",#status)
  EndIf
  ClearStructure(@nowPlaying,nowPlaying)
  nowPlaying\ID = -1
  SetGadgetText(#toolbarPlayPause,#playSymbol)
  SetWindowTitle(#wnd,#myNameVer)
  SetGadgetText(#nowPlaying,"")
  SetGadgetText(#nowPlayingDuration,"[standby]")
  SetGadgetState(#nowPlayingProgress,0)
  If lyricsAvailable
    SetGadgetText(#lyrics,"")
  EndIf
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

Macro sizeGadgets()
  ResizeGadget(#playlist,#PB_Ignore,#PB_Ignore,WindowWidth(#wnd)-500,WindowHeight(#wnd))
  ResizeGadget(#albumArt,WindowWidth(#wnd)-500,#PB_Ignore,#PB_Ignore,#PB_Ignore)
  ResizeGadget(#nowPlaying,WindowWidth(#wnd)-500,#PB_Ignore,#PB_Ignore,#PB_Ignore)
  ResizeGadget(#nowPlayingDuration,WindowWidth(#wnd)-500,#PB_Ignore,#PB_Ignore,#PB_Ignore)
  ResizeGadget(#nowPlayingProgress,WindowWidth(#wnd)-495,#PB_Ignore,#PB_Ignore,#PB_Ignore)
  ResizeGadget(#toolbarPreviousAlbum,WindowWidth(#wnd)-495,#PB_Ignore,#PB_Ignore,#PB_Ignore)
  ResizeGadget(#toolbarPrevious,WindowWidth(#wnd)-445,#PB_Ignore,#PB_Ignore,#PB_Ignore)
  ResizeGadget(#toolbarPlayPause,WindowWidth(#wnd)-395,#PB_Ignore,#PB_Ignore,#PB_Ignore)
  ResizeGadget(#toolbarNext,WindowWidth(#wnd)-345,#PB_Ignore,#PB_Ignore,#PB_Ignore)
  ResizeGadget(#toolbarNextAlbum,WindowWidth(#wnd)-295,#PB_Ignore,#PB_Ignore,#PB_Ignore)
  ResizeGadget(#toolbarStop,WindowWidth(#wnd)-245,#PB_Ignore,#PB_Ignore,#PB_Ignore)
  ResizeGadget(#toolbarLyricsReloadWeb,WindowWidth(#wnd)-55,#PB_Ignore,#PB_Ignore,#PB_Ignore)      
  ResizeGadget(#lyrics,WindowWidth(#wnd)-500,#PB_Ignore,#PB_Ignore,WindowHeight(#wnd)-620)
EndMacro

Macro flushSettings()
  saveSettings()
  loadSettings()
EndMacro