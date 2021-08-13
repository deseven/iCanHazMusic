EnableExplicit

Threaded _IsMainScope
_IsMainScope = #True

IncludeFile "const.pb"
IncludeFile "helpers.pb"
IncludeFile "../pb-macos-audioplayer/audioplayer.pbi"
IncludeFile "../pb-httprequest-manager/httprequest-manager.pbi"

NewList tagsToGet.track_info()
NewList playQueue.i()
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
Define tagsToGetLock.i = CreateMutex()
Define lastfmToken.s,lastfmSession.s,lastfmUser.s
Define lastfmTokenResponse.s,lastfmSessionResponse.s
Define sharedApp.i = CocoaMessage(0,0,"NSApplication sharedApplication")
Define appDelegate.i = CocoaMessage(0,sharedApp,"delegate")
Define delegateClass.i = CocoaMessage(0,appDelegate,"class")
Define lastPlayedID.i
Define alphaAlertShownFor.s
Define nextID.i
Define ffprobe.s
Define ffprobeVer.s
Define lyricsAvailable.b
Define dropCount.i
Define *response.HTTPRequestManager::response
Define responseResult.s
Define lastHTTPRequestManagerProcess.i

; nowplaying update stuff
Define currentTimeSec.i
Define durationSec.i
Define oldCurrent.i
Define newCurrent.i
Define lastDurationUpdate.i
Define currentAlbum.s
Define numAlbums.i

; playback stuff
Define cursorFollowsPlayback.b
Define playbackFollowsCursor.b
Define playbackOrder.b
Define stopAtQueueEnd.b
Define queueEnded.b
NewList history.i()
Define historyEnabled.b

Global EXIT = #False

UseMD5Fingerprint()
UsePNGImageDecoder()
UseJPEGImageDecoder()
UseZipPacker()
InitNetwork()
HTTPRequestManager::init(1,30000,#myUserAgent,0,#True)

If FileSize(dataDir) <> -2 : CreateDirectory(dataDir) : EndIf
If FileSize(dataDir + "/lyrics") <> -2 : CreateDirectory(dataDir + "/lyrics") : EndIf
If FileSize(dataDir + "/tmp") <> -2
  CreateDirectory(dataDir + "/tmp")
Else
  DeleteDirectory(dataDir + "/tmp","*.*",#PB_FileSystem_Recursive|#PB_FileSystem_Force)
  CreateDirectory(dataDir + "/tmp")
EndIf

IncludeFile "proc.pb"

ffprobe = findffprobe()
If ffprobe
  debugLog("main","found ffprobe " + ffprobeVer + " (" + ffprobe + ")")
Else
  If MessageRequester(#myName,#noffprobeMsg,#PB_MessageRequester_YesNo) = #PB_MessageRequester_Yes
    installffprobe()
  Else
    End 1
  EndIf
EndIf

lyricsAvailable = canLoadLyrics()

ExamineDesktops()
OpenWindow(#wnd,0,0,1280,720,#myNameVer,#PB_Window_SizeGadget|#PB_Window_SizeGadget|#PB_Window_SystemMenu|#PB_Window_MinimizeGadget|#PB_Window_ScreenCentered)
WindowBounds(#wnd,1280,720,#PB_Ignore,#PB_Ignore)

CreateMenu(#menu,WindowID(#wnd))

MenuTitle("File")
MenuItem(#openPlaylist,"Open Playlist...")
MenuItem(#savePlaylist,"Save Playlist...")
MenuBar()
MenuItem(#addDirectory,"Add Diectory...")
MenuItem(#addFile,"Add File(s)...")

MenuTitle("Playback")
MenuItem(#playbackCursorFollowsPlayback,"Cursor follows playback")
MenuItem(#playbackPlaybackFollowsCursor,"Playback follows cursor")
OpenSubMenu("Order")
MenuItem(#playbackOrderDefault,"Default")
MenuItem(#playbackOrderShuffleTracks,"Shuffle (tracks)")
MenuItem(#playbackOrderShuffleAlbums,"Shuffle (albums)")
CloseSubMenu()
MenuBar()
MenuItem(#playbackStopAtQueueEnd,"Stop at queue end")

MenuTitle("Last.fm")
MenuItem(#lastfmState,"")
MenuBar()
MenuItem(#lastfmUser,"")
DisableMenuItem(#menu,#lastfmUser,#True)

CreatePopupMenu(#playlistMenu)
MenuItem(#playlistQueue,"Queue")
MenuItem(#playlistPlay,"Play" + Chr(9) + "⏎")
MenuItem(#playlistReloadTags,"Reload tags" + Chr(9) + "R")
MenuItem(#playlistRemove,"Remove from playlist" + Chr(9) + "⌫")

ListIconGadget(#playlist,0,0,WindowWidth(#wnd)-500,WindowHeight(#wnd),"",35)
AddGadgetColumn(#playlist,#file,"File",200)
AddGadgetColumn(#playlist,#track,"#",25)
AddGadgetColumn(#playlist,#artist,"Artist",200)
AddGadgetColumn(#playlist,#title,"Title",200)
AddGadgetColumn(#playlist,#duration,"Duration",65)
AddGadgetColumn(#playlist,#album,"Album",150)
AddGadgetColumn(#playlist,#details,"Details",80)

ListIconGadgetHideColumn(#playlist,#file,#True)
SetListIconColumnJustification(#playlist,#status,#justifyCenter)
SetListIconColumnJustification(#playlist,#track,#justifyRight)
SetListIconColumnJustification(#playlist,#duration,#justifyCenter)
SetListIconColumnJustification(#playlist,#details,#justifyRight)
;CocoaMessage(0,GadgetID(#playlist),"setGridStyleMask:",1)
;CocoaMessage(0, GadgetID(#playlist), "setUsesAlternatingRowBackgroundColors:", #YES)
;CocoaMessage(0, GadgetID(#playlist), "setUsesAutomaticRowHeights:", #YES)
CocoaMessage(0,GadgetID(#playlist),"setAllowsTypeSelect:",#NO)

CreateImage(#defaultAlbumArt,500,500)
StartDrawing(ImageOutput(#defaultAlbumArt))
Box(0,0,500,500,0)
DrawText(500/2-TextWidth("[no album art]")/2,500/2-TextHeight("[no album art]")/2,"[no album art]",$CCCCCC,0)
StopDrawing()
ImageGadget(#albumArt,WindowWidth(#wnd)-500,0,500,500,ImageID(#defaultAlbumArt))

TextGadget(#nowPlaying,WindowWidth(#wnd)-500,500,500,59,"",#PB_Text_Center)
TextGadget(#nowPlayingDuration,WindowWidth(#wnd)-500,559,500,16,"[standby]",#PB_Text_Center)
ProgressBarGadget(#nowPlayingProgress,WindowWidth(#wnd)-495,575,490,20,0,100)

ButtonGadget(#toolbarPreviousAlbum,WindowWidth(#wnd)-495,595,50,25,#previousAlbumSymbol)
ButtonGadget(#toolbarPrevious,WindowWidth(#wnd)-445,595,50,25,#previousSymbol)
ButtonGadget(#toolbarPlayPause,WindowWidth(#wnd)-395,595,50,25,#playSymbol)
ButtonGadget(#toolbarNext,WindowWidth(#wnd)-345,595,50,25,#nextSymbol)
ButtonGadget(#toolbarNextAlbum,WindowWidth(#wnd)-295,595,50,25,#nextAlbumSymbol)
ButtonGadget(#toolbarStop,WindowWidth(#wnd)-245,595,50,25,#stopSymbol)
ButtonGadget(#toolbarLyricsReloadWeb,WindowWidth(#wnd)-55,595,50,25,#refreshSymbol)

GadgetToolTip(#toolbarPreviousAlbum,"Previous Album")
GadgetToolTip(#toolbarPrevious,"Previous Track")
GadgetToolTip(#toolbarPlayPause,"Play/Pause")
GadgetToolTip(#toolbarNext,"Next Track")
GadgetToolTip(#toolbarNextAlbum,"Next Album")
GadgetToolTip(#toolbarStop,"Stop")
GadgetToolTip(#toolbarLyricsReloadWeb,"Reload lyrics from Genius")

EditorGadget(#lyrics,WindowWidth(#wnd)-500,620,500,WindowHeight(#wnd)-620,#PB_Editor_ReadOnly|#PB_Editor_WordWrap)
If Not lyricsAvailable
  SetGadgetText(#lyrics,"[lyrics disabled]")
  HideGadget(#lyrics,#True)
EndIf
HideGadget(#toolbarLyricsReloadWeb,#True)

debugLog("main","interface loaded")

class_addMethod_(delegateClass,sel_registerName_("applicationDockMenu:"),@dockMenuHandler(),"v@:@")
CocoaMessage(0,sharedApp,"setDelegate:",appDelegate)
class_addMethod_(delegateClass,sel_registerName_("tableView:isGroupRow:"),@IsGroupRow(),"v@:@@")
CocoaMessage(0,GadgetID(#playlist),"setDelegate:",appDelegate)
debugLog("main","handlers registered")

loadSettings()
sizeGadgets()
loadState()
updateLastfmStatus()
loadSettings() ; temporary hack to redraw the playlist

AddKeyboardShortcut(#wnd,#PB_Shortcut_Q,#playlistQueue)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Return|#PB_Shortcut_Shift,#playlistQueue)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Space,#playlistQueue)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Return,#playlistPlay)
AddKeyboardShortcut(#wnd,#PB_Shortcut_R,#playlistReloadTags)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Back,#playlistRemove)

EnableGadgetDrop(#playlist,#PB_Drop_Files,#PB_Drag_Copy|#PB_Drag_Move|#PB_Drag_Link)

MenuItem(#PB_Menu_Preferences,"")
MenuItem(#PB_Menu_About,"")

nowPlaying\ID = -1
debugLog("main","ready to play")

If alphaAlertShownFor <> #myVer
  MessageRequester(#myNameVer,#alphaWarning,#PB_MessageRequester_Warning)
EndIf
alphaAlertShownFor = #myVer

Define timeoutTime.i = #defaultTimeout

Repeat
  ev = WaitWindowEvent(timeoutTime)
  
  ; audioplayer routine
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
  
  ; HTTPRequestManager routine
  If lastHTTPRequestManagerProcess + 900 <= ElapsedMilliseconds()
    HTTPRequestManager::process()
    lastHTTPRequestManagerProcess = ElapsedMilliseconds()
  EndIf
  
  ; event processing
  Select ev
      
    Case #PB_Event_CloseWindow
      Select EventWindow()
        Case #wnd
          Break
        Case #wndPrefs
          saveSettings()
      EndSelect
      CloseWindow(EventWindow())
      
    ; menu events
    Case #PB_Event_Menu
      Select EventMenu()
        Case #openPlaylist
          If CountGadgetItems(#playlist) = 0 Or 
             (CountGadgetItems(#playlist) And MessageRequester(#myName,"Your current playlist will be cleared, are sure you want to continue?",#PB_MessageRequester_YesNo|#PB_MessageRequester_Warning) = #PB_MessageRequester_Yes)
            playlist = OpenFileRequester("Select playlist","","",0)
            If FileSize(playlist) > 0 And ReadFile(0,playlist)
              cleanUp()
              i = 0
              CocoaMessage(0,GadgetID(#playlist),"beginUpdates")
              While Eof(0) = 0
                playlistString = ReadString(0)
                If Left(playlistString,1) = "#" Or Len(playlistString) < 2
                  Continue
                EndIf
                If audioplayer::isSupportedFile(playlistString) And FileSize(playlistString) > 0
                  AddElement(tagsToGet())
                  tagsToGet()\id = i
                  tagsToGet()\path = playlistString
                  AddGadgetItem(#playlist,-1,#processingSymbol + #sep + tagsToGet()\path)
                  i + 1
                EndIf
              Wend
              CocoaMessage(0,GadgetID(#playlist),"endUpdates")
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
              If Not GetGadgetItemData(#playlist,i)
                playlistString + ~"\n" + GetGadgetItemText(#playlist,i,#file)
              EndIf
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
                CocoaMessage(0,GadgetID(#playlist),"beginUpdates")
                ForEach filesInDirectory()
                  If audioplayer::isSupportedFile(filesInDirectory())
                    AddElement(tagsToGet())
                    tagsToGet()\id = i
                    tagsToGet()\path = filesInDirectory()
                    AddGadgetItem(#playlist,-1,#processingSymbol + #sep + filesInDirectory())
                    i + 1
                  EndIf
                Next
                CocoaMessage(0,GadgetID(#playlist),"endUpdates")
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
                AddGadgetItem(#playlist,-1,#processingSymbol + #sep + file)
                i + 1
              EndIf
              file = NextSelectedFileName()
            Wend
            doTags()
          Else
            MessageRequester(#myName,"Please wait until current parsing is completed",#PB_MessageRequester_Error)
          EndIf
        Case #playlistPlay
          PostEvent(#PB_Event_Gadget,#wnd,#playlist,#PB_EventType_LeftDoubleClick)
        Case #playlistQueue
          If isQueued(GetGadgetState(#playlist))
            queueRemove(GetGadgetState(#playlist))
          Else
            queueAdd(GetGadgetState(#playlist))
          EndIf
        Case #playlistReloadTags
          If isParsingCompleted()
            If GetGadgetItemData(#playlist,GetGadgetState(#playlist))
              Define albumToTagReload.s = GetGadgetItemText(#playlist,GetGadgetState(#playlist),#album)
              For i = GetGadgetState(#playlist) + 1 To CountGadgetItems(#playlist)-1
                If GetGadgetItemText(#playlist,i,#album) <> albumToTagReload
                  Break
                EndIf
                SetGadgetItemText(#playlist,i,#processingSymbol,#status)
                AddElement(tagsToGet())
                tagsToGet()\id = i
                tagsToGet()\path = GetGadgetItemText(#playlist,i,#file)
              Next
            Else
              SetGadgetItemText(#playlist,GetGadgetState(#playlist),#processingSymbol,#status)
              AddElement(tagsToGet())
              tagsToGet()\id = GetGadgetState(#playlist)
              tagsToGet()\path = GetGadgetItemText(#playlist,GetGadgetState(#playlist),#file)
            EndIf
            doTags()
          Else
            MessageRequester(#myName,"Please wait until current parsing is completed",#PB_MessageRequester_Error)
          EndIf
        Case #playlistRemove
          If GetGadgetItemData(#playlist,GetGadgetState(#playlist))
            Define albumToRemove.s = GetGadgetItemText(#playlist,GetGadgetState(#playlist),#album)
            For i = GetGadgetState(#playlist) To CountGadgetItems(#playlist)-1
              If GetGadgetItemText(#playlist,i,#album) <> albumToRemove
                Break
              EndIf
              RemoveGadgetItem(#playlist,i)
              i - 1 ; because we removed an item and the next one is having the same id now
            Next
          Else
            RemoveGadgetItem(#playlist,GetGadgetState(#playlist))
          EndIf
          setAlbums()
          saveState()
        Case #playbackCursorFollowsPlayback
          cursorFollowsPlayback = 1-cursorFollowsPlayback
          SetMenuItemState(#menu,#playbackCursorFollowsPlayback,cursorFollowsPlayback)
          saveSettings()
        Case #playbackPlaybackFollowsCursor
          playbackFollowsCursor = 1-playbackFollowsCursor
          SetMenuItemState(#menu,#playbackPlaybackFollowsCursor,playbackFollowsCursor)
          saveSettings()
        Case #playbackStopAtQueueEnd
          stopAtQueueEnd = 1-stopAtQueueEnd
          SetMenuItemState(#menu,#playbackStopAtQueueEnd,stopAtQueueEnd)
          saveSettings()
        Case #playbackOrderDefault
          SetMenuItemState(#menu,#playbackOrderDefault,#True)
          SetMenuItemState(#menu,#playbackOrderShuffleTracks,#False)
          SetMenuItemState(#menu,#playbackOrderShuffleAlbums,#False)
          playbackOrder = #orderDefault
          saveSettings()
        Case #playbackOrderShuffleTracks
          SetMenuItemState(#menu,#playbackOrderDefault,#False)
          SetMenuItemState(#menu,#playbackOrderShuffleTracks,#True)
          SetMenuItemState(#menu,#playbackOrderShuffleAlbums,#False)
          playbackOrder = #orderShuffleTracks
          saveSettings()
        Case #playbackOrderShuffleAlbums
          SetMenuItemState(#menu,#playbackOrderDefault,#False)
          SetMenuItemState(#menu,#playbackOrderShuffleTracks,#False)
          SetMenuItemState(#menu,#playbackOrderShuffleAlbums,#True)
          playbackOrder = #orderShuffleAlbums
          saveSettings()
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
        Case #dockNextAlbum
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarNextAlbum)
        Case #dockPrevious
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarPrevious)
        Case #dockPreviousAlbum
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarPreviousAlbum)  
        Case #PB_Menu_Quit
          Break
        Case #PB_Menu_Preferences
          prefs()
        Case #PB_Menu_About
          MessageRequester(#myNameVer,~"written by deseven, 2021\n\nLicense: UNLICENSE\nURL: " + #myURL)
      EndSelect
      
    ; gadget events
    Case #PB_Event_Gadget
      Select EventGadget()
        Case #playlist
          Select EventType()
            Case #PB_EventType_LeftDoubleClick
              If GetGadgetState(#playlist) > -1
                If isParsingCompleted()
                  If GetGadgetItemData(#playlist,GetGadgetState(#playlist))
                    SetGadgetState(#playlist,GetGadgetState(#playlist) + 1)
                  EndIf
                  queueClear()
                  queueEnded = #False
                  nextID = GetGadgetState(#playlist)
                  currentAlbum = GetGadgetItemText(#playlist,nextID,#album)
                  historyEnabled = #True
                  doPlay()
                  saveSettings()
                Else
                  MessageRequester(#myName,"Please wait until current parsing is completed",#PB_MessageRequester_Error)
                EndIf
              EndIf
            Case #PB_EventType_RightClick
              If GetGadgetState(#playlist) <> -1
                If isQueued(GetGadgetState(#playlist))
                  SetMenuItemText(#playlistMenu,#playlistQueue,"Remove from queue" + Chr(9) + "␣")
                Else
                  SetMenuItemText(#playlistMenu,#playlistQueue,"Add to queue" + Chr(9) + "␣")
                EndIf
                DisplayPopupMenu(#playlistMenu,WindowID(#wnd))
              EndIf
          EndSelect
        Case #toolbarLyricsReloadWeb
          If lyricsAvailable
            If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
            HideGadget(#toolbarLyricsReloadWeb,#True)
            SetGadgetText(#lyrics,"[looking for lyrics...]")
            lyricsThread = CreateThread(@lyrics(),#True)
          EndIf
        Case #toolbarPlayPause
          If nowPlaying\ID = -1
            nextID = queueNext()
            If nextID > -1 And nextID < CountGadgetItems(#playlist)
              If cursorFollowsPlayback
                SetGadgetState(#playlist,nextID)
              EndIf
            EndIf
            If GetGadgetState(#playlist) > -1
              PostEvent(#PB_Event_Gadget,#wnd,#playlist,#PB_EventType_LeftDoubleClick)
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
        Case #toolbarNext,#toolbarPrevious,#toolbarNextAlbum,#toolbarPreviousAlbum
          Select EventGadget()
            Case #toolbarNext
              debugLog("playback","next track")
              nextID = getNextTrack()
            Case #toolbarNextAlbum
              debugLog("playback","next album")
              queueClear() ; todo - make queue support for that
              nextID = getNextAlbum()
            Case #toolbarPrevious
              debugLog("playback","previous track")
              nextID = getPreviousTrack()
            Case #toolbarPreviousAlbum
              debugLog("playback","previous album")
              ClearList(history()) ; todo - make history support for that
              nextID = getPreviousAlbum()
          EndSelect
          If cursorFollowsPlayback
            SetGadgetState(#playlist,nextID)
          EndIf
          If nextID <> -1
            doPlay()
            saveSettings()
          Else
            doStop()
          EndIf
      EndSelect
      
    ; drag'n'drop processing
    Case #PB_Event_GadgetDrop
      If EventGadget() = #playlist
        Select dropCount
          Case 0
            MessageRequester(#myName,"Ouch... Drag'n'Drop is not supported yet, please don't drop stuff on me!",#PB_MessageRequester_Warning)
          Case 1
            MessageRequester(#myName,"Stop dropping stuff on me!",#PB_MessageRequester_Warning)
          Case 2
            MessageRequester(#myName,"Dude please... It's not going to work.",#PB_MessageRequester_Warning)
          Case 3
            MessageRequester(#myName,"...",#PB_MessageRequester_Warning)
          Case 4
            MessageRequester(#myName,"You're still doing this in hopes to find something cool? There's nothing.",#PB_MessageRequester_Warning)
          Case 5,6,7
            MessageRequester(#myName,"TODO: write more funny answers for drag'n'drop operations",#PB_MessageRequester_Info)
          Case 8
            MessageRequester(#myName,"You really got nothing to do, don't you?",#PB_MessageRequester_Warning)
          Case 9
            MessageRequester(#myName,"Come on...",#PB_MessageRequester_Warning)
          Case 10 To 20
            MessageRequester(#myName,"Maybe you simply love wasting your time?",#PB_MessageRequester_Warning)
          Case 21
            MessageRequester(#myName,"Oh sure you do...",#PB_MessageRequester_Warning)
          Case 22
            MessageRequester(#myName,"Are you also waiting for a conclusion of some sort?",#PB_MessageRequester_Warning)
          Case 23
            MessageRequester(#myName,"How about a story?",#PB_MessageRequester_Info)
          Case 24
            MessageRequester("🤬","I AM A FUCKING AUDIO PLAYER I DON'T TELL STORIES",#PB_MessageRequester_Error)
          Case 25
            MessageRequester("😡","")
          Case 26
            MessageRequester("😑","You know what... I'll just quit.")
          Case 27
            MessageRequester("😔","No, seriously, you do whatever you like, i'm out!")
          Case 28
            MessageRequester("👋","Bye.")
            RunProgram("open","https://www.youtube.com/watch?v=cr6eFl7hCiA","")
            Break
        EndSelect
        dropCount + 1
      EndIf
      
    ; window events
    Case #PB_Event_SizeWindow
      sizeGadgets()
      saveSettings()
    Case #PB_Event_MoveWindow
      saveSettings()
      
    ; custom events
    Case #evTagGetSuccess
      *elem = EventData()
      With *elem
        If CountString(\tags\track,"/")
          \tags\track = StringField(\tags\track,1,"/")
        EndIf
        \tags\track = LTrim(\tags\track,"0")
        SetGadgetItemText(#playlist,\id,#sep + 
                                        \path + #sep + 
                                        \tags\track + #sep +
                                        \tags\artist + #sep + 
                                        \tags\title + #sep + 
                                        \duration + #sep +
                                        \tags\album + #sep + 
                                        UCase(\format) + " " + Str(\bitrate/1000) + "k")
        ;debugLog("main","incoming tag for " + \path)
      EndWith
    Case #evTagGetFail
      *elem = EventData()
      SetGadgetItemText(#playlist,*elem\id,"[failed to get artist]",#artist)
      SetGadgetItemText(#playlist,*elem\id,"[failed to get title]",#title)
    Case #evTagGetFinish
      If isParsingCompleted(#False)
        If ListSize(tagsParserThreads())
          ClearList(tagsParserThreads())
          CreateThread(@DelayEvent(),#evTagGetSaveState)
        EndIf
      EndIf
    Case #evTagGetSaveState
      setAlbums()
      saveState()
      ClearList(tagsToGet())
    Case #evPlayStart
      If lastfmSession
        debugLog("lastfm","updating nowplaying " + Str(nowPlaying\ID))
        lastfmUpdateNowPlaying()
      EndIf
    Case #evPlayFinish
      debugLog("playback","track ended")
      If lastfmSession
        debugLog("lastfm","scrobbling " + Str(nowPlaying\ID))
        lastfmScrobble()
      EndIf
      PostEvent(#PB_Event_Gadget,#wnd,#toolbarNext)
    Case #evLyricsFail
      SetGadgetText(#lyrics,"[no lyrics found]")
      HideGadget(#toolbarLyricsReloadWeb,#False)
    Case #evLyricsSuccessGenius,#evLyricsSuccessFile
      SetGadgetText(#lyrics,nowPlaying\lyrics)
      HideGadget(#toolbarLyricsReloadWeb,#False)
      If ev = #evLyricsSuccessFile
        debugLog("lyrics","successfully loaded from file")
      Else
        debugLog("lyrics","successfully loaded from Genius")
      EndIf
    Case #evNowPlayingRequestFinished,#evScrobbleRequestFinished
      *response = HTTPRequestManager::getResponse(EventData())
      If *response
        responseResult = HTTPRequestManager::getComment(EventData())
        Select HTTPRequestManager::getStatus(EventData())
          Case HTTPRequestManager::#TimedOut
            responseResult + " timed out"
          Case HTTPRequestManager::#Failed
            responseResult + " failed with error: " + *response\error
          Case HTTPRequestManager::#Success
            If *response\statusCode = 200
              If ev = #evNowPlayingRequestFinished
                responseResult + " was successfull"
              ElseIf ev = #evScrobbleRequestFinished
                If FindString(*response\response,~"\"accepted\":1")
                  responseResult + " was successfull"
                ElseIf FindString(*response\response,~"\"ignored\":1")
                  responseResult + " was ignored"
                Else
                  responseResult + " failed with http code " + Str(*response\statusCode) + ": " + *response\response
                EndIf
              EndIf
            Else
              responseResult + " failed with http code " + Str(*response\statusCode) + ": " + *response\response
            EndIf
        EndSelect
        debugLog("lastfm",responseResult)
      Else
        debugLog("lastfm","got answer for " + Str(EventData()) + " with no response")
      EndIf
    Case #evUpdateNowPlaying
      updateNowPlaying(EventType(),EventData())
  EndSelect
  
ForEver

saveSettings()
die()
debugLog("main","exiting")