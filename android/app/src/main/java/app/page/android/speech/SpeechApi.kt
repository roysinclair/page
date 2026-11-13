package app.page.android.speech

import android.content.Context
import android.content.Intent
import android.speech.ModelDownloadListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import java.util.concurrent.Executor

// The speech calls that exist only on newer Androids (minSdk is 26), each in a helper that says so. The controller
// reaches them only behind a `Build.VERSION.SDK_INT` check, and the types they name never appear in the controller's
// own signatures, so an older phone never has to resolve them. API levels from platforms/android-35/data/api-versions.xml.

/** API 31: is there a recognizer that keeps the audio on the phone, and make one. */
@RequiresApi(31)
internal object OnDeviceSpeech {
    fun available(context: Context): Boolean = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    fun create(context: Context): SpeechRecognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
}

/** The on-device languages a recognizer lists, as BCP 47 tags. */
internal class OnDeviceLanguages(val installed: List<String>, val supported: List<String>, val pending: List<String>)

/** API 33: which languages the on-device recognizer has, can fetch, or is fetching. */
@RequiresApi(33)
internal object OnDeviceSupport {
    fun check(recognizer: SpeechRecognizer, intent: Intent, executor: Executor, result: (OnDeviceLanguages) -> Unit, failed: (Int) -> Unit) {
        recognizer.checkRecognitionSupport(intent, executor, object : RecognitionSupportCallback {
            override fun onSupportResult(support: RecognitionSupport) {
                result(OnDeviceLanguages(support.installedOnDeviceLanguages, support.supportedOnDeviceLanguages, support.pendingOnDeviceLanguages))
            }

            override fun onError(error: Int) = failed(error)
        })
    }

    /** API 33 has no listener: the download starts and the caller asks again until the language is installed. */
    fun triggerDownload(recognizer: SpeechRecognizer, intent: Intent) = recognizer.triggerModelDownload(intent)
}

/** API 34: the download reports its progress, and says when it is done. */
@RequiresApi(34)
internal object OnDeviceDownload {
    fun trigger(
        recognizer: SpeechRecognizer, intent: Intent, executor: Executor,
        progress: (Int) -> Unit, scheduled: () -> Unit, succeeded: () -> Unit, failed: (Int) -> Unit,
    ) {
        recognizer.triggerModelDownload(intent, executor, object : ModelDownloadListener {
            override fun onProgress(completedPercent: Int) = progress(completedPercent)

            override fun onSuccess() = succeeded()

            override fun onScheduled() = scheduled()

            override fun onError(error: Int) = failed(error)
        })
    }
}
