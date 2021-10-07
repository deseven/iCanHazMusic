window.onload = function() {
    
    let albumArt = document.getElementById('albumArt');
    let nowPlaying = document.getElementById('nowPlaying');
    let track = document.getElementById('track');
    let album = document.getElementById('album');
    let details = document.getElementById('details');

    let previousAlbum = document.getElementById('previousAlbum');
    let previous = document.getElementById('previous');
    let playPause = document.getElementById('playPause');
    let next = document.getElementById('next');
    let nextAlbum = document.getElementById('nextAlbum');
    let stop = document.getElementById('stop');
    let auth = 'ichm';

    let currentID;
    let currentTrack;
    let currentAlbum;
    let currentDetails;
    let errorNotification;
    let npRequest;
    let npRequestCompleted = true;

    function ichmUnavailable() {
        errorNotification = SimpleNotification.error({
            text: 'iCanHazMusic is not available'
        },{
            position: 'bottom-center',
            sticky: true,
            closeButton: false,
            closeOnClick: false,
            removeAllOnDisplay: true,
            insertAnimation: {name:'',duration:0},
            removeAnimation: {name:'',duration:0}
        });
    }

    function toolbarHandler(event) {
        switch(event.target) {
            case playPause:
                method = 'playPause';
                break;
            case previousAlbum:
                method = 'previousAlbum';
                break;
            case previous:
                method = 'previous';
                break;
            case playPause:
                method = 'playPause';
                break;
            case next:
                method = 'next';
                break;
            case nextAlbum:
                method = 'nextAlbum';
                break;
            case stop:
                method = 'stop';
        }

        var toolbarRequest = new XMLHttpRequest();
        toolbarRequest.open('GET','/api/?' + method);
        toolbarRequest.timeout = 5000;
        toolbarRequest.send();
        toolbarRequest.onload = function() {
            if (toolbarRequest.status != 200) {
                SimpleNotification.error({
                    text: 'command failed'
                },{
                    duration: 1000,
                    position: 'top-center',
                    removeAllOnDisplay: true,
                    //insertAnimation: {name:'',duration:0},
                    //removeAnimation: {name:'',duration:0}
                });
            } else {
                SimpleNotification.success({
                    text: 'command sent'
                },{
                    duration: 1000,
                    position: 'top-center',
                    removeAllOnDisplay: true,
                    //insertAnimation: {name:'',duration:0},
                    //removeAnimation: {name:'',duration:0}
                });
            }
        }
        updateStatus();
    }

    previousAlbum.onclick = toolbarHandler;
    previous.onclick = toolbarHandler;
    playPause.onclick = toolbarHandler;
    next.onclick = toolbarHandler;
    nextAlbum.onclick = toolbarHandler;
    stop.onclick = toolbarHandler;

    function updateStatus() {
        if (!npRequestCompleted) {
            return;
        }
        npRequestCompleted = false;
        npRequest = new XMLHttpRequest();
        npRequest.onload = function() {
            npRequestCompleted = true;
            if (npRequest.status == 401) {
                npRequestCompleted = false;
                auth = prompt('Please input you iCHM password:',auth);
                setCookie('ichm-auth',auth,3650);
                npRequestCompleted = true;
            } else if (npRequest.status != 200) {
                ichmUnavailable();
            } else {
                try {
                    nowPlayingData = JSON.parse(npRequest.response);
                    //console.log(nowPlayingData);
                    if (currentID != nowPlayingData.ID) {
                        currentID = nowPlayingData.ID;
                        albumArt.innerHTML = '<img width="300" height="300" src="api/?albumart&ts=' + new Date().getTime() +'">';
                    }
                    if (nowPlayingData.ID != -1) {
                        if ((nowPlayingData.artist + ' - ' + nowPlayingData.title) != currentTrack) {
                            currentTrack = nowPlayingData.artist + ' - ' + nowPlayingData.title;
                            track.innerHTML = currentTrack;
                            track.className = '';
                            if (isElementOverflowing(track)) {
                                track.className = 'marquee';
                            }
                        }
                        if (nowPlayingData.album != currentAlbum) {
                            currentAlbum = nowPlayingData.album;
                            album.innerHTML = currentAlbum;
                            album.className = '';
                            if (isElementOverflowing(album)) {
                                album.className = 'marquee';
                            }
                        }
                        if (nowPlayingData.details != currentDetails) {
                            currentDetails = nowPlayingData.details;
                            details.innerHTML = currentDetails;
                            details.className = '';
                            if (isElementOverflowing(details)) {
                                details.className = 'marquee';
                            }
                        }
                        
                        if (nowPlayingData.isPaused == 1) {
                            playPause.className = 'play';
                        } else {
                            playPause.className = 'pause';
                        }
                    } else {
                        track.innerHTML = '[stopped]';
                        track.className = '';
                        album.innerHTML = '';
                        album.className = '';
                        details.innerHTML = '';
                        details.className = '';
                        currentTrack = '[stopped]';
                        currentAlbum = '';
                        currentDetails = '';
                        playPause.className = 'play';
                    }
                    if (errorNotification) {
                        errorNotification.remove();
                    }
                } catch(e) {
                    console.error(e);
                    ichmUnavailable();
                }
            }
        };
        npRequest.onerror = function() {
            ichmUnavailable();
            npRequestCompleted = true;
        };
        npRequest.open('GET','/api/?nowplaying');
        npRequest.timeout = 5000;
        npRequest.ontimeout = function(e) {
            npRequestCompleted = true;
            ichmUnavailable();
            npRequest.abort();
        }
        npRequest.send();
    }

    updateStatus();
    setInterval(updateStatus,2000);
}