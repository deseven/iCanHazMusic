EnableExplicit

Threaded _IsMainScope
_IsMainScope = #True

IncludeFile "const.pb"
IncludeFile "helpers.pb"
IncludeFile "../pb-macos-audioplayer/audioplayer.pbi"

NewList tagsToGet.track_info()
Define ev.i
Define playlist.s,directory.s,file.s
NewList filesInDirectory.s()
NewList tagsParserThreads.i()
Define lyricsThread.i
Define i.i,j.i
Define skip.b
Define *elem.track_info
Define playlistString.s
Define nowPlaying.nowPlaying
Define dataDir.s = GetEnvironmentVariable("HOME") + "/Library/Application Support/" + #myName
Define systemThreads.l = CountCPUs(#PB_System_ProcessCPUs)
If systemThreads > 4 : systemThreads = 4 : EndIf ; more than enough
Define numThreads.b
Define lastfmUpdateNowPlayingThread
Define lastfmScrobbleThread
Define nowPlayingSemaphore = CreateSemaphore()
Define tagsToGetLock.i = CreateMutex()
Define lastfmToken.s,lastfmSession.s,lastfmUser.s
Define lastfmTokenResponse.s,lastfmSessionResponse.s
Define lastfmScrobbleError.s,lastfmUpdateError.s
Define sharedApp.i = CocoaMessage(0,0,"NSApplication sharedApplication")
Define appDelegate.i = CocoaMessage(0,sharedApp,"delegate")
Define delegateClass.i = CocoaMessage(0,appDelegate,"class")

; nowplaying update stuff
Define currentTimeSec.i
Define durationSec.i
Define oldCurrent.i
Define newCurrent.i
Define lastDurationUpdate.i

Global EXIT = #False

UseMD5Fingerprint()
UsePNGImageDecoder()
UseJPEGImageDecoder()
InitNetwork()

If FileSize(dataDir) <> -2 : CreateDirectory(dataDir) : EndIf
If FileSize(dataDir + "/lyrics") <> -2 : CreateDirectory(dataDir + "/lyrics") : EndIf
If FileSize(dataDir + "/tmp") <> -2
  CreateDirectory(dataDir + "/tmp")
Else
  DeleteDirectory(dataDir + "/tmp","*.*",#PB_FileSystem_Recursive|#PB_FileSystem_Force)
  CreateDirectory(dataDir + "/tmp")
EndIf

IncludeFile "proc.pb"

ExamineDesktops()
OpenWindow(#wnd,0,0,DesktopWidth(0),DesktopHeight(0),#myName,#PB_Window_SizeGadget|#PB_Window_SizeGadget|#PB_Window_SystemMenu|#PB_Window_MinimizeGadget)
WindowBounds(#wnd,800,720,#PB_Ignore,#PB_Ignore)

CreateMenu(#menu,WindowID(#wnd))
MenuTitle("File")
MenuItem(#openPlaylist,"Open Playlist...")
MenuItem(#savePlaylist,"Save Playlist...")
MenuBar()
MenuItem(#addDirectory,"Add Diectory...")
MenuItem(#addFile,"Add File(s)...")
MenuTitle("Last.fm")
MenuItem(#lastfmState,"")
MenuBar()
MenuItem(#lastfmUser,"")
DisableMenuItem(#menu,#lastfmUser,#True)

CreatePopupMenu(#playlistMenu)
MenuItem(#playlistReloadTags,"Reload tags")
MenuItem(#playlistRemove,"Remove from playlist")
MenuItem(#playlistRemoveAlbum,"Remove album from playlist")

ListIconGadget(#playlist,0,0,WindowWidth(#wnd)-500,WindowHeight(#wnd),"",20)
AddGadgetColumn(#playlist,#file,"File",200)
AddGadgetColumn(#playlist,#track,"#",30)
AddGadgetColumn(#playlist,#artist,"Artist",300)
AddGadgetColumn(#playlist,#title,"Title",300)
AddGadgetColumn(#playlist,#duration,"Duration",65)
AddGadgetColumn(#playlist,#album,"Album",250)
AddGadgetColumn(#playlist,#details,"Details",150)

CreateImage(#defaultAlbumArt,500,500)
StartDrawing(ImageOutput(#defaultAlbumArt))
Box(0,0,500,500,0)
DrawText(500/2-TextWidth("[no album art]")/2,500/2-TextHeight("[no album art]")/2,"[no album art]",$CCCCCC,0)
StopDrawing()
ImageGadget(#albumArt,WindowWidth(#wnd)-500,0,500,500,ImageID(#defaultAlbumArt))

TextGadget(#nowPlaying,WindowWidth(#wnd)-500,500,500,59,"",#PB_Text_Center)
TextGadget(#nowPlayingDuration,WindowWidth(#wnd)-500,559,500,16,"[standby]",#PB_Text_Center)
ProgressBarGadget(#nowPlayingProgress,WindowWidth(#wnd)-495,575,490,20,0,100)

ButtonGadget(#toolbarPrevious,WindowWidth(#wnd)-495,595,50,25,#previousSymbol)
ButtonGadget(#toolbarPlayPause,WindowWidth(#wnd)-445,595,50,25,#playSymbol)
ButtonGadget(#toolbarNext,WindowWidth(#wnd)-395,595,50,25,#nextSymbol)
ButtonGadget(#toolbarStop,WindowWidth(#wnd)-345,595,50,25,#stopSymbol)
ButtonGadget(#toolbarLyricsReloadWeb,WindowWidth(#wnd)-55,595,50,25,#refreshSymbol)

EditorGadget(#lyrics,WindowWidth(#wnd)-500,620,500,WindowHeight(#wnd)-620,#PB_Editor_ReadOnly|#PB_Editor_WordWrap)

debugLog("main","interface loaded")

loadState()
loadSettings()

updateLastfmStatus()

nowPlaying\ID = -1

class_addMethod_(delegateClass,sel_registerName_("applicationDockMenu:"),@dockMenuHandler(),"v@:@")
CocoaMessage(0,sharedApp,"setDelegate:",appDelegate)
debugLog("main","handlers registered")

Define timeoutTime.i = #defaultTimeout

Repeat
  ev = WaitWindowEvent(timeoutTime)
  If audioplayer::getPlayer() And nowPlaying\ID <> -1 And nowPlaying\isPaused = #False
    If lastDurationUpdate + 900 <= ElapsedMilliseconds()
      lastDurationUpdate = ElapsedMilliseconds()
      newCurrent = audioplayer::getCurrentTime()/1000
      If oldCurrent <> newCurrent
        oldCurrent = newCurrent
        PostEvent(#evUpdateNowPlaying,#wnd,0,newCurrent,nowPlaying\durationSec)
      EndIf
    EndIf
    audioplayer::checkFinishRoutine()
  EndIf
  Select ev
    Case #PB_Event_CloseWindow
      Break
    Case #PB_Event_Menu
      Select EventMenu()
        Case #openPlaylist
          If CountGadgetItems(#playlist) = 0 Or (CountGadgetItems(#playlist) And MessageRequester(#myName,"Your current playlist will be cleared, are sure you want to continue?",#PB_MessageRequester_YesNo|#PB_MessageRequester_Warning) = #PB_MessageRequester_Yes)
            playlist = OpenFileRequester("Select playlist","","",0)
            If FileSize(playlist) > 0 And ReadFile(0,playlist)
              cleanUp()
              i = 0
              While Eof(0) = 0
                playlistString = ReadString(0)
                If Left(playlistString,1) = "#"
                  Continue
                EndIf
                If audioplayer::isSupportedFile(playlistString) And FileSize(playlistString) > 0
                  AddElement(tagsToGet())
                  tagsToGet()\id = i
                  tagsToGet()\path = playlistString
                  AddGadgetItem(#playlist,-1,#sep + tagsToGet()\path)
                  i + 1
                EndIf
              Wend
              CloseFile(0)
              doTags()
            Else
              MessageRequester(#myName,"Can't open file " + playlist,#PB_MessageRequester_Error)
            EndIf
          EndIf
        Case #savePlaylist
          playlist = SaveFileRequester("Save playlist","main.m3u8","",0)
          If playlist
            playlistString = ~"#EXTM3U\n"
            For i = 0 To CountGadgetItems(#playlist)-1
              playlistString + ~"\n" + GetGadgetItemText(#playlist,i,#file)
            Next
            If Not WriteFileFast(playlist,playlistString)
              MessageRequester(#myName,"Failed to save current playlist to " + playlist,#PB_MessageRequester_Error)
            EndIf
          EndIf
        Case #addDirectory
          If isParsingCompleted()
            directory = PathRequester("Select directory","")
            If FileSize(directory) = -2
              ClearList(filesInDirectory())
              RecursiveDirectorySafe(directory,filesInDirectory())
              If ListSize(filesInDirectory())
                SortList(filesInDirectory(),#PB_Sort_Ascending|#PB_Sort_NoCase)
                i = CountGadgetItems(#playlist)
                ForEach filesInDirectory()
                  If audioplayer::isSupportedFile(filesInDirectory())
                    AddElement(tagsToGet())
                    tagsToGet()\id = i
                    tagsToGet()\path = filesInDirectory()
                    AddGadgetItem(#playlist,-1,#sep + filesInDirectory())
                    i + 1
                  EndIf
                Next
                doTags()
              EndIf
            EndIf
          Else
            MessageRequester(#myName,"Please wait until current parsing is completed",#PB_MessageRequester_Error)
          EndIf
        Case #addFile
          If isParsingCompleted()
            file = OpenFileRequester("Select file(s)","","",0,#PB_Requester_MultiSelection)
            i = CountGadgetItems(#playlist)
            While file
              If audioplayer::isSupportedFile(file)
                AddElement(tagsToGet())
                tagsToGet()\id = i
                tagsToGet()\path = file
                AddGadgetItem(#playlist,-1,#sep + file)
                i + 1
              EndIf
              file = NextSelectedFileName()
            Wend
            doTags()
          Else
            MessageRequester(#myName,"Please wait until current parsing is completed",#PB_MessageRequester_Error)
          EndIf
        Case #playlistReloadTags
          If isParsingCompleted()
            AddElement(tagsToGet())
            tagsToGet()\id = GetGadgetState(#playlist)
            tagsToGet()\path = GetGadgetItemText(#playlist,GetGadgetState(#playlist),#file)
            doTags()
          Else
            MessageRequester(#myName,"Please wait until current parsing is completed",#PB_MessageRequester_Error)
          EndIf
        Case #playlistRemove
          RemoveGadgetItem(#playlist,GetGadgetState(#playlist))
          saveState()
        Case #playlistRemoveAlbum
          Define albumToRemove.s = GetGadgetItemText(#playlist,GetGadgetState(#playlist),#album)
          For i = GetGadgetState(#playlist) + 1 To CountGadgetItems(#playlist)-1
            If GetGadgetItemText(#playlist,i,#album) <> albumToRemove
              Debug GetGadgetItemText(#playlist,i,#album)
              Debug albumToRemove
              Break
            EndIf
            RemoveGadgetItem(#playlist,i)
            i - 1 ; because we removed an item and the next one is having the same id now
          Next
          For i = GetGadgetState(#playlist) To 0 Step -1
            If GetGadgetItemText(#playlist,i,#album) <> albumToRemove
              Break
            EndIf
            RemoveGadgetItem(#playlist,i)
          Next
          saveState()
        Case #lastfmState
          If lastfmSession
            If MessageRequester(#myName,"Do you really want to log out of Last.fm? Scrobbling will be disabled.",#PB_MessageRequester_YesNo|#PB_MessageRequester_Warning) = #PB_MessageRequester_Yes
              lastfmSession = ""
              lastfmUser = ""
              saveSettings()
              updateLastfmStatus()
            EndIf
          Else
            If lastfmAuth(#getToken)
              MessageRequester(#myName,"You're going to be redirected to Last.fm in order to authorize " + #myName + " for scrobbling. Press OK to continue.")
              lastfmAuth(#openAuthLink)
              Delay(1000)
              MessageRequester(#myName,"Press OK again when you finished.")
              While Not lastfmAuth(#getSession)
                If MessageRequester(#myName,~"Failed getting session for Last.fm, want to try again?\n\n" + lastfmSessionResponse,#PB_MessageRequester_YesNo|#PB_MessageRequester_Error) = #PB_MessageRequester_No
                  Break
                EndIf
              Wend
              If lastfmSession And lastfmUser
                MessageRequester(#myName,"You are successfully logged in as " + lastfmUser,#PB_MessageRequester_Info)
                updateLastfmStatus()
              EndIf
              saveSettings()
            Else
              MessageRequester(#myName,~"Failed getting auth token for Last.fm, please try again later and if the problem persists, contact the developer.\n\n" + lastfmTokenResponse,#PB_MessageRequester_Error)
            EndIf
          EndIf
        Case #lastfmUser
          If lastfmUser
            RunProgram("open","https://www.last.fm/user/" + lastfmUser,"")
          EndIf
        Case #dockPlayPause
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarPlayPause)
        Case #dockStop
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarStop)
        Case #dockNext
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarNext)
        Case #dockPrevious
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarPrevious)
        Case #PB_Menu_Quit
          Break
      EndSelect
    Case #PB_Event_Gadget
      Select EventGadget()
        Case #playlist
          Select EventType()
            Case #PB_EventType_LeftDoubleClick
              If GetGadgetState(#playlist) > -1
                doPlay()
                saveSettings()
              EndIf
            Case #PB_EventType_RightClick
              If GetGadgetState(#playlist) <> -1
                DisplayPopupMenu(#playlistMenu,WindowID(#wnd))
              EndIf
          EndSelect
        Case #toolbarPlayPause
          If nowPlaying\ID = -1
            If GetGadgetState(#playlist) > -1
              doPlay()
              saveSettings()
            EndIf
          ElseIf audioplayer::getPlayer()
            If nowPlaying\isPaused
              nowPlaying\isPaused = #False
              audioplayer::play()
              debugLog("playback","continued")
              SetGadgetText(#toolbarPlayPause,#pauseSymbol)
            Else
              nowPlaying\isPaused = #True
              audioplayer::pause()
              debugLog("playback","paused")
              SetGadgetText(#toolbarPlayPause,#playSymbol)
            EndIf
          EndIf
        Case #toolbarStop
          If nowPlaying\ID <> -1
            doStop()
          EndIf
        Case #toolbarNext
          debugLog("playback","next")
          If nowPlaying\ID <> - 1
            If nowPlaying\ID < CountGadgetItems(#playlist) - 1
              SetGadgetState(#playlist,nowPlaying\ID + 1)
              doPlay()
              saveSettings()
            Else
              doStop()
              SetGadgetState(#playlist,-1)
            EndIf
          EndIf
        Case #toolbarPrevious
          If nowPlaying\ID <> - 1
            If nowPlaying\ID > 0
              SetGadgetState(#playlist,nowPlaying\ID - 1)
              doPlay()
              saveSettings()
            Else
              doStop()
              SetGadgetState(#playlist,-1)
            EndIf
          EndIf
      EndSelect
    Case #PB_Event_SizeWindow
      ResizeGadget(#playlist,#PB_Ignore,#PB_Ignore,WindowWidth(#wnd)-500,WindowHeight(#wnd))
      ResizeGadget(#albumArt,WindowWidth(#wnd)-500,#PB_Ignore,#PB_Ignore,#PB_Ignore)
      ResizeGadget(#nowPlaying,WindowWidth(#wnd)-500,#PB_Ignore,#PB_Ignore,#PB_Ignore)
      ResizeGadget(#nowPlayingDuration,WindowWidth(#wnd)-500,#PB_Ignore,#PB_Ignore,#PB_Ignore)
      ResizeGadget(#nowPlayingProgress,WindowWidth(#wnd)-495,#PB_Ignore,#PB_Ignore,#PB_Ignore)
      ResizeGadget(#toolbarPrevious,WindowWidth(#wnd)-495,#PB_Ignore,#PB_Ignore,#PB_Ignore)
      ResizeGadget(#toolbarPlayPause,WindowWidth(#wnd)-445,#PB_Ignore,#PB_Ignore,#PB_Ignore)
      ResizeGadget(#toolbarNext,WindowWidth(#wnd)-395,#PB_Ignore,#PB_Ignore,#PB_Ignore)
      ResizeGadget(#toolbarStop,WindowWidth(#wnd)-345,#PB_Ignore,#PB_Ignore,#PB_Ignore)
      ResizeGadget(#toolbarLyricsReloadWeb,WindowWidth(#wnd)-55,#PB_Ignore,#PB_Ignore,#PB_Ignore)      
      ResizeGadget(#lyrics,WindowWidth(#wnd)-500,#PB_Ignore,#PB_Ignore,WindowHeight(#wnd)-620)
    Case #evTagGetSuccess
      *elem = EventData()
      With *elem
        SetGadgetItemText(#playlist,\id,#sep + 
                                        \path + #sep + 
                                        \tags\track + #sep +
                                        \tags\artist + #sep + 
                                        \tags\title + #sep + 
                                        \duration + #sep +
                                        \tags\album + #sep + 
                                        UCase(\format) + " " + Str(\bitrate/1000) + "k")
      EndWith
    Case #evTagGetFail
      *elem = EventData()
      SetGadgetItemText(#playlist,*elem\id,"[failed to get artist]",#artist)
      SetGadgetItemText(#playlist,*elem\id,"[failed to get title]",#title)
    Case #evTagGetFinish
      If isParsingCompleted()
        If ListSize(tagsParserThreads())
          ClearList(tagsParserThreads())
          CreateThread(@DelayEvent(),#evTagGetSaveState)
        EndIf
      EndIf
    Case #evTagGetSaveState
      saveState()
      ClearList(tagsToGet())
    Case #evPlayStart
      If lastfmSession
        debugLog("lastfm","updating nowplaying " + Str(nowPlaying\ID))
        lastfmUpdateNowPlayingThread = CreateThread(@lastfmUpdateNowPlaying(),0)
        WaitSemaphore(nowPlayingSemaphore)
      EndIf
    Case #evPlayFinish
      debugLog("playback","track ended")
      If lastfmSession
        debugLog("lastfm","scrobbling " + Str(nowPlaying\ID))
        lastfmScrobbleThread = CreateThread(@lastfmScrobble(),0)
        WaitSemaphore(nowPlayingSemaphore)
      EndIf
      PostEvent(#PB_Event_Gadget,#wnd,#toolbarNext)
    Case #evLyricsFail
      SetGadgetText(#lyrics,"[no lyrics found]")
    Case #evLyricsSuccessGenius,#evLyricsSuccessFile
      SetGadgetText(#lyrics,nowPlaying\lyrics)
      If ev = #evLyricsSuccessFile
        debugLog("lyrics","successfully loaded from file")
      Else
        debugLog("lyrics","successfully loaded from Genius")
      EndIf
    Case #evLastfmScrobbleSuccess
      debugLog("lastfm","scrobbled " + Str(EventData()))
    Case #evLastfmScrobbleError
      debugLog("lastfm",lastfmScrobbleError)
    Case #evLastfmUpdateSuccess
      debugLog("lastfm","updated nowplaying " + Str(EventData()))
    Case #evLastfmUpdateError
      debugLog("lastfm",lastfmUpdateError)
    Case #evUpdateNowPlaying
      updateNowPlaying(EventType(),EventData())
  EndSelect
ForEver

die()
debugLog("main","exiting")