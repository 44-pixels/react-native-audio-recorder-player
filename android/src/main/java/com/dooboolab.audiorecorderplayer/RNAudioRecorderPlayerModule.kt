package com.dooboolab.audiorecorderplayer

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule.RCTDeviceEventEmitter
import com.facebook.react.modules.core.PermissionListener
import java.io.IOException
import java.util.*
import kotlin.math.log10

// symmetrical to TS - 'recording' | 'paused' | 'interrupted' | 'stopped';
private enum class RecordingState {
    RECORDING,
    PAUSED,
    STOPPED,
    INTERRUPTED,
    ERROR;

    fun mapToReactState(): String {
        return when(this) {
            RecordingState.RECORDING -> "recording"
            RecordingState.PAUSED -> "paused"
            RecordingState.STOPPED -> "stopped"
            RecordingState.INTERRUPTED -> "interrupted"
            RecordingState.ERROR -> "stopped"
        }
    }
}

class RNAudioRecorderPlayerModule(private val reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext), PermissionListener {
    private var audioFileURL = ""
    private var subsDurationMillis = 500
    private var _meteringEnabled = false
    private var mediaRecorder: MediaRecorder? = null
    private var mediaPlayer: MediaPlayer? = null
    private var recorderRunnable: Runnable? = null
    private var mTask: TimerTask? = null
    private var mTimer: Timer? = null
    private var pausedRecordTime = 0L
    private var totalPausedRecordTime = 0L
    var recordHandler: Handler? = Handler(Looper.getMainLooper())
    
    // Audio focus management for handling call interruptions
    private var audioManager: AudioManager? = null
    private var audioFocusChangeListener: AudioManager.OnAudioFocusChangeListener? = null
    private var wasRecordingBeforeInterruption = false
    
    override fun getName(): String {
        return tag
    }

    /**
     * Added functionality.
     * Self managed state, mediaRecorder does no provide state listeners.
     **/
    private var recordingState: RecordingState? = null
    private fun updateRecordingState(newState: RecordingState) {
        recordingState = newState
        val obj = Arguments.createMap()
        obj.putString("state", newState.mapToReactState())
        sendEvent(reactContext, "rn-recording-state", obj)
    }
    
    /**
     * Set up audio focus to handle interruptions like incoming calls.
     * When audio focus is lost (e.g., phone call), recording will be paused.
     */
    private fun setupAudioFocus() {
        audioManager = reactContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        
        audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
            when (focusChange) {
                AudioManager.AUDIOFOCUS_LOSS,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                    // Another app took audio focus - pause recording
                    if (mediaRecorder != null && recordingState == RecordingState.RECORDING) {
                        Log.d(tag, "Audio focus lost, pausing recording")
                        wasRecordingBeforeInterruption = true
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                mediaRecorder?.pause()
                                pausedRecordTime = SystemClock.elapsedRealtime()
                                recorderRunnable?.let { recordHandler?.removeCallbacks(it) }
                                updateRecordingState(RecordingState.INTERRUPTED)
                            }
                        } catch (e: Exception) {
                            Log.e(tag, "Error pausing recorder on focus loss: ${e.message}")
                        }
                    }
                }
                AudioManager.AUDIOFOCUS_GAIN -> {
                    // Audio focus regained - auto-resume if we were recording before interruption
                    // This matches iOS behavior which also auto-resumes after interruption
                    Log.d(tag, "Audio focus regained")
                    if (wasRecordingBeforeInterruption && mediaRecorder != null && 
                        recordingState == RecordingState.INTERRUPTED) {
                        // Delay before resuming to match iOS behavior (0.5 seconds)
                        // This avoids conflicts with other apps that may still be releasing resources
                        Handler(Looper.getMainLooper()).postDelayed({
                            try {
                                // Verify foreground service is still running and recorder is valid
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && 
                                    mediaRecorder != null &&
                                    RecordingForegroundService.isServiceRunning()) {
                                    mediaRecorder?.resume()
                                    totalPausedRecordTime += SystemClock.elapsedRealtime() - pausedRecordTime
                                    recorderRunnable?.let { recordHandler?.postDelayed(it, subsDurationMillis.toLong()) }
                                    updateRecordingState(RecordingState.RECORDING)
                                    Log.d(tag, "Recording resumed after interruption")
                                } else {
                                    Log.w(tag, "Cannot resume: service not running or recorder null")
                                    updateRecordingState(RecordingState.PAUSED)
                                }
                            } catch (e: Exception) {
                                Log.e(tag, "Error resuming recorder after interruption: ${e.message}")
                                // If resume fails, update state to paused so app knows
                                updateRecordingState(RecordingState.PAUSED)
                            }
                            wasRecordingBeforeInterruption = false
                        }, 500) // 500ms delay to match iOS interruptionRecoveryDelay
                    }
                }
            }
        }
        
        // Request audio focus
        @Suppress("DEPRECATION")
        audioManager?.requestAudioFocus(
            audioFocusChangeListener,
            AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN
        )
    }
    
    /**
     * Release audio focus when recording stops.
     */
    private fun releaseAudioFocus() {
        audioFocusChangeListener?.let { listener ->
            @Suppress("DEPRECATION")
            audioManager?.abandonAudioFocus(listener)
        }
        audioFocusChangeListener = null
        audioManager = null
        wasRecordingBeforeInterruption = false
    }

    @ReactMethod
    fun startRecorder(path: String, audioSet: ReadableMap?, meteringEnabled: Boolean, promise: Promise) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // On devices that run Android 10 (API level 29) or higher
                // your app can contribute to well-defined media collections such as MediaStore.Downloads without requesting any storage-related permissions
                // https://developer.android.com/about/versions/11/privacy/storage#permissions-target-11
                if (Build.VERSION.SDK_INT < 29 &&
                        (ActivityCompat.checkSelfPermission(reactContext, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED ||
                        ActivityCompat.checkSelfPermission(reactContext, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED))  {
                    ActivityCompat.requestPermissions(reactContext.currentActivity!!, arrayOf(
                            Manifest.permission.RECORD_AUDIO,
                            Manifest.permission.WRITE_EXTERNAL_STORAGE), 0)
                    promise.reject("No permission granted.", "Try again after adding permission.")
                    return
                } else if (ActivityCompat.checkSelfPermission(reactContext, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    ActivityCompat.requestPermissions(reactContext.currentActivity!!, arrayOf(Manifest.permission.RECORD_AUDIO), 0)
                    promise.reject("No permission granted.", "Try again after adding permission.")
                    return
                }
            }
        } catch (ne: NullPointerException) {
            Log.w(tag, ne.toString())
            promise.reject("No permission granted.", "Try again after adding permission.")
            return
        }

        var outputFormat = if (audioSet != null && audioSet.hasKey("OutputFormatAndroid"))
            audioSet.getInt("OutputFormatAndroid")
        else
            MediaRecorder.OutputFormat.MPEG_4

        audioFileURL = if (((path == "DEFAULT"))) "${reactContext.cacheDir}/sound.${defaultFileExtensions.get(outputFormat)}" else path
        _meteringEnabled = meteringEnabled

        if (mediaRecorder != null) {
            promise.reject("InvalidState", "startRecorder has already been called.")
            return
        }

        // Start foreground service BEFORE starting the MediaRecorder
        // This ensures we have permission to use the microphone in background
        try {
            RecordingForegroundService.start(reactContext)
        } catch (e: Exception) {
            Log.w(tag, "Failed to start foreground service, recording may not work in background: ${e.message}")
            // Continue anyway - recording will still work in foreground
        }
        
        // Set up audio focus to handle interruptions (e.g., incoming calls)
        setupAudioFocus()

        var newMediaRecorder: MediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(reactContext)
        } else {
            MediaRecorder()
        }

        try {
            newMediaRecorder.setOnInfoListener { _, what, extra ->
                when (what) {
                    MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED -> {
                        Log.w(tag, "Max duration reached — stopping")
                        stopRecorderInternal()
                    }

                    MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED -> {
                        Log.w(tag, "Max file size reached — stopping")
                        stopRecorderInternal()
                    }
                }
            }
            newMediaRecorder.setOnErrorListener { _, what, extra ->
                Log.e(tag, "Error: what=$what extra=$extra")
                updateRecordingState(RecordingState.ERROR)
            }
            if (audioSet == null) {
                newMediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
                newMediaRecorder.setOutputFormat(outputFormat)
                newMediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            } else {
                newMediaRecorder.setAudioSource(if (audioSet.hasKey("AudioSourceAndroid")) audioSet.getInt("AudioSourceAndroid") else MediaRecorder.AudioSource.MIC)
                newMediaRecorder.setOutputFormat(outputFormat)
                newMediaRecorder.setAudioEncoder(if (audioSet.hasKey("AudioEncoderAndroid")) audioSet.getInt("AudioEncoderAndroid") else MediaRecorder.AudioEncoder.AAC)

                if (audioSet.hasKey("AudioSamplingRateAndroid")) {
                    newMediaRecorder.setAudioSamplingRate(audioSet.getInt("AudioSamplingRateAndroid"))
                }

                if (audioSet.hasKey("AudioEncodingBitRateAndroid")) {
                    newMediaRecorder.setAudioEncodingBitRate(audioSet.getInt("AudioEncodingBitRateAndroid"))
                }

                if (audioSet.hasKey("AudioChannelsAndroid")) {
                    newMediaRecorder.setAudioChannels(audioSet.getInt("AudioChannelsAndroid"))
                }
            }
            newMediaRecorder.setOutputFile(audioFileURL)

            newMediaRecorder.prepare()
            totalPausedRecordTime = 0L
            newMediaRecorder.start()

            updateRecordingState(RecordingState.RECORDING)

            mediaRecorder = newMediaRecorder

            val systemTime = SystemClock.elapsedRealtime()
            recorderRunnable = object : Runnable {
                override fun run() {
                    val time = SystemClock.elapsedRealtime() - systemTime - totalPausedRecordTime
                    val obj = Arguments.createMap()
                    obj.putDouble("currentPosition", time.toDouble())
                    if (_meteringEnabled) {
                        var maxAmplitude = 0
                        if (mediaRecorder != null) {
                            maxAmplitude = mediaRecorder!!.maxAmplitude
                        }
                        var dB = -160.0
                        val maxAudioSize = 32767.0
                        if (maxAmplitude > 0) {
                            dB = 20 * log10(maxAmplitude / maxAudioSize)
                        }
                        obj.putInt("currentMetering", dB.toInt())
                    }
                    obj.putBoolean("isRecording", recordingState == RecordingState.RECORDING)
                    sendEvent(reactContext, "rn-recordback", obj)
                    recordHandler!!.postDelayed(this, subsDurationMillis.toLong())
                }
            }
            (recorderRunnable as Runnable).run()
            promise.resolve("file:///$audioFileURL")
        } catch (e: Exception) {
            newMediaRecorder.release()
            mediaRecorder = null
            
            // Release audio focus
            releaseAudioFocus()
            
            // Stop foreground service if recording failed to start
            try {
                RecordingForegroundService.stop(reactContext)
            } catch (serviceError: Exception) {
                Log.w(tag, "Failed to stop foreground service: ${serviceError.message}")
            }

            Log.e(tag, "Exception: ", e)
            promise.reject("startRecord", e.message)
        }
    }

    @ReactMethod
    fun resumeRecorder(promise: Promise) {
        if (mediaRecorder == null) {
            promise.reject("resumeRecorder", "Recorder is null.")
            return
        }

        try {
            mediaRecorder!!.resume()
            totalPausedRecordTime += SystemClock.elapsedRealtime() - pausedRecordTime;
            recorderRunnable?.let { recordHandler!!.postDelayed(it, subsDurationMillis.toLong()) }
            updateRecordingState(RecordingState.RECORDING)
            promise.resolve("Recorder resumed.")
        } catch (e: Exception) {
            Log.e(tag, "Recorder resume: " + e.message)
            promise.reject("resumeRecorder", e.message)
        }
    }

    @ReactMethod
    fun pauseRecorder(promise: Promise) {
        if (mediaRecorder == null) {
            promise.reject("pauseRecorder", "Recorder is null.")
            return
        }

        try {
            mediaRecorder!!.pause()
            pausedRecordTime = SystemClock.elapsedRealtime();
            recorderRunnable?.let { recordHandler!!.removeCallbacks(it) }
            updateRecordingState(RecordingState.PAUSED)
            promise.resolve("Recorder paused.")
        } catch (e: Exception) {
            Log.e(tag, "pauseRecorder exception: " + e.message)
            promise.reject("pauseRecorder", e.message)
        }
    }

    @ReactMethod
    fun stopRecorder(promise: Promise) {
        try {
            val fileUrl = stopRecorderInternal()
            promise.resolve("file:///$fileUrl")
        } catch (e: Exception) {
            promise.reject("stopRecord", e.message, e)
        }
    }

    private fun stopRecorderInternal(): String {
        recordHandler?.removeCallbacks(recorderRunnable ?: return "")

        if (mediaRecorder == null) {
            throw IllegalStateException("Recorder is null.")
        }

        try {
            mediaRecorder!!.stop()
            mediaRecorder!!.release()
            mediaRecorder = null
            updateRecordingState(RecordingState.STOPPED)
            
            // Release audio focus
            releaseAudioFocus()
            
            // Stop the foreground service now that recording is complete
            try {
                RecordingForegroundService.stop(reactContext)
            } catch (e: Exception) {
                Log.w(tag, "Failed to stop foreground service: ${e.message}")
            }
            
            return audioFileURL // return the path (no scheme prefix)
        } catch (e: RuntimeException) {
            mediaRecorder = null
            updateRecordingState(RecordingState.ERROR)
            
            // Release audio focus
            releaseAudioFocus()
            
            // Stop the foreground service even on error
            try {
                RecordingForegroundService.stop(reactContext)
            } catch (serviceError: Exception) {
                Log.w(tag, "Failed to stop foreground service: ${serviceError.message}")
            }
            
            throw e
        }
    }

    @ReactMethod
    fun setVolume(volume: Double, promise: Promise) {
        if (mediaPlayer == null) {
            promise.reject("setVolume", "player is null.")
            return
        }

        val mVolume = volume.toFloat()
        mediaPlayer!!.setVolume(mVolume, mVolume)
        promise.resolve("set volume")
    }

    @ReactMethod
    fun setPlaybackSpeed(playbackSpeed: Float, promise: Promise) {
        if (mediaPlayer == null) {
            promise.reject("setPlaybackSpeed", "player is null.")
            return
        }
        mediaPlayer!!.playbackParams = mediaPlayer!!.playbackParams.setSpeed(playbackSpeed)
        promise.resolve("setPlaybackSpeed")
    }

    @ReactMethod
    fun startPlayer(path: String, httpHeaders: ReadableMap?, promise: Promise) {
        if (mediaPlayer != null) {
            val isPaused = !mediaPlayer!!.isPlaying && mediaPlayer!!.currentPosition > 1

            if (isPaused) {
                mediaPlayer!!.start()
                promise.resolve("player resumed.")
                return
            }

            Log.e(tag, "Player is already running. Stop it first.")
            promise.reject("startPlay", "Player is already running. Stop it first.")
            return
        } else {
            mediaPlayer = MediaPlayer()
        }

        try {
            if ((path == "DEFAULT")) {
                mediaPlayer!!.setDataSource("${reactContext.cacheDir}/$defaultFileName")
            } else {
                if (httpHeaders != null) {
                    val headers: MutableMap<String, String?> = HashMap<String, String?>()
                    val iterator = httpHeaders.keySetIterator()
                    while (iterator.hasNextKey()) {
                        val key = iterator.nextKey()
                        headers.put(key, httpHeaders.getString(key))
                    }
                    mediaPlayer!!.setDataSource(reactContext.applicationContext, Uri.parse(path), headers)
                } else {
                    mediaPlayer!!.setDataSource(path)
                }
            }

            mediaPlayer!!.setOnPreparedListener { mp ->
                Log.d(tag, "Mediaplayer prepared and start")
                mp.start()
                /**
                 * Set timer task to send event to RN.
                 */
                mTask = object : TimerTask() {
                    override fun run() {
                        try {
                            val obj = Arguments.createMap()
                            obj.putInt("duration", mp.duration)
                            obj.putInt("currentPosition", mp.currentPosition)
                            obj.putBoolean("isFinished", false);
                            sendEvent(reactContext, "rn-playback", obj)
                        } catch (e: IllegalStateException) {
                            // IllegalStateException 처리
                            Log.e(tag, "Mediaplayer error: ${e.message}")
                        }
                    }
                }

                mTimer = Timer()
                mTimer!!.schedule(mTask, 0, subsDurationMillis.toLong())
                val resolvedPath = if (((path == "DEFAULT"))) "${reactContext.cacheDir}/$defaultFileName" else path
                promise.resolve(resolvedPath)
            }

            /**
             * Detect when finish playing.
             */
            mediaPlayer!!.setOnCompletionListener { mp ->
                /**
                 * Send last event
                 */
                val obj = Arguments.createMap()
                obj.putInt("duration", mp.duration)
                obj.putInt("currentPosition", mp.currentPosition)
                obj.putBoolean("isFinished", true);
                sendEvent(reactContext, "rn-playback", obj)
                /**
                 * Reset player.
                 */
                Log.d(tag, "Plays completed.")
                mTimer?.cancel()
                mp.stop()
                mp.reset()
                mp.release()
                mediaPlayer = null
            }

            mediaPlayer!!.prepare()
        } catch (e: IOException) {
            Log.e(tag, "startPlay() io exception")
            promise.reject("startPlay", e.message)
        } catch (e: NullPointerException) {
            Log.e(tag, "startPlay() null exception")
        }
    }

    @ReactMethod
    fun resumePlayer(promise: Promise) {
        if (mediaPlayer == null) {
            promise.reject("resume", "Mediaplayer is null on resume.")
            return
        }

        if (mediaPlayer!!.isPlaying) {
            promise.reject("resume", "Mediaplayer is already running.")
            return
        }

        try {
            mediaPlayer!!.seekTo(mediaPlayer!!.currentPosition)
            mediaPlayer!!.start()
            promise.resolve("resume player")
        } catch (e: Exception) {
            Log.e(tag, "Mediaplayer resume: " + e.message)
            promise.reject("resume", e.message)
        }
    }

    @ReactMethod
    fun pausePlayer(promise: Promise) {
        if (mediaPlayer == null) {
            promise.reject("pausePlay", "Mediaplayer is null on pause.")
            return
        }

        try {
            mediaPlayer!!.pause()
            promise.resolve("pause player")
        } catch (e: Exception) {
            Log.e(tag, "pausePlay exception: " + e.message)
            promise.reject("pausePlay", e.message)
        }
    }

    @ReactMethod
    fun seekToPlayer(time: Double, promise: Promise) {
        if (mediaPlayer == null) {
            promise.reject("seekTo", "Mediaplayer is null on seek.")
            return
        }

        mediaPlayer!!.seekTo(time.toInt())
        promise.resolve("pause player")
    }

    private fun sendEvent(reactContext: ReactContext,
                          eventName: String,
                          params: WritableMap?) {
        reactContext
                .getJSModule<RCTDeviceEventEmitter>(RCTDeviceEventEmitter::class.java)
                .emit(eventName, params)
    }

    @ReactMethod
    fun stopPlayer(promise: Promise) {
        if (mTimer != null) {
            mTimer!!.cancel()
        }

        if (mediaPlayer == null) {
            promise.resolve("Already stopped player")
            return
        }

        try {
            mediaPlayer!!.stop()
            mediaPlayer!!.reset()
            mediaPlayer!!.release()
            mediaPlayer = null
            promise.resolve("stopped player")
        } catch (e: Exception) {
            Log.e(tag, "stopPlay exception: " + e.message)
            promise.reject("stopPlay", e.message)
        }
    }

    @ReactMethod
    fun setSubscriptionDuration(sec: Double, promise: Promise) {
        subsDurationMillis = (sec * 1000).toInt()
        promise.resolve("setSubscriptionDuration: $subsDurationMillis")
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray): Boolean {
        var requestRecordAudioPermission: Int = 200

        when (requestCode) {
            requestRecordAudioPermission -> if (grantResults[0] == PackageManager.PERMISSION_GRANTED) return true
        }

        return false
    }

    companion object {
        private var tag = "RNAudioRecorderPlayer"
        private var defaultFileName = "sound.mp4"
        private var defaultFileExtensions = listOf(
            "mp4", // DEFAULT = 0
            "3gp", // THREE_GPP
            "mp4", // MPEG_4
            "amr", // AMR_NB
            "amr", // AMR_WB
            "aac", // AAC_ADIF
            "aac", // AAC_ADTS
            "rtp", // OUTPUT_FORMAT_RTP_AVP
            "ts",  // MPEG_2_TSMPEG_2_TS
            "webm",// WEBM
            "xxx", // UNUSED
            "ogg", // OGG
        )
    }
}
