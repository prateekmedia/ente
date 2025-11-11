package io.ente.photos

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

@Serializable
data class MemoryFileData(val title: String?, val subText: String?, val generatedId: Int?)

class EnteMemoryWidgetProvider : HomeWidgetProvider() {
        companion object {
                private const val SLIDESHOW_UPDATE_INTERVAL = 30000L // 30 seconds
        }

        override fun onUpdate(
                context: Context,
                appWidgetManager: AppWidgetManager,
                appWidgetIds: IntArray,
                widgetData: SharedPreferences
        ) {
                appWidgetIds.forEach { widgetId ->
                        val views =
                                RemoteViews(context.packageName, R.layout.memory_widget_layout)
                                        .apply {
                                                val totalMemories =
                                                        widgetData.getInt("totalMemories", 0)

                                                // Get or initialize current index for slideshow
                                                val currentIndex = widgetData.getInt("memory_current_index", 0)
                                                var photoIndex = -1
                                                var imagePath: String? = null

                                                if (totalMemories > 0) {
                                                        // Cycle through photos sequentially
                                                        photoIndex = currentIndex % totalMemories
                                                        imagePath =
                                                                widgetData.getString(
                                                                        "memory_widget_$photoIndex",
                                                                        null
                                                                )

                                                        // Save next index for next update
                                                        widgetData.edit()
                                                                .putInt("memory_current_index", currentIndex + 1)
                                                                .apply()
                                                }

                                                var imageExists: Boolean = false
                                                if (imagePath != null) {
                                                        val imageFile = File(imagePath)
                                                        imageExists = imageFile.exists()
                                                }
                                                if (imageExists) {
                                                        val data =
                                                                widgetData.getString(
                                                                        "memory_widget_${photoIndex}_data",
                                                                        null
                                                                )
                                                        val decoded: MemoryFileData? =
                                                                data?.let {
                                                                        Json.decodeFromString<
                                                                                MemoryFileData>(it)
                                                                }
                                                        val title = decoded?.title
                                                        val subText = decoded?.subText
                                                        val generatedId = decoded?.generatedId

                                                        val deepLinkUri =
                                                                Uri.parse(
                                                                        "memorywidget://message?generatedId=${generatedId}&homeWidget"
                                                                )

                                                        val pendingIntent =
                                                                HomeWidgetLaunchIntent.getActivity(
                                                                        context,
                                                                        MainActivity::class.java,
                                                                        deepLinkUri
                                                                )

                                                        setOnClickPendingIntent(
                                                                R.id.widget_container,
                                                                pendingIntent
                                                        )

                                                        Log.d(
                                                                "EnteMemoryWidgetProvider",
                                                                "Image exists: $imagePath"
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_img,
                                                                View.VISIBLE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_subtitle,
                                                                View.VISIBLE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_title,
                                                                View.VISIBLE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_overlay,
                                                                View.VISIBLE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_placeholder,
                                                                View.GONE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_placeholder_text,
                                                                View.GONE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_placeholder_container,
                                                                View.GONE
                                                        )

                                                        val bitmap: Bitmap =
                                                                BitmapFactory.decodeFile(imagePath)
                                                        setImageViewBitmap(R.id.widget_img, bitmap)
                                                        setTextViewText(R.id.widget_title, title)
                                                        setTextViewText(
                                                                R.id.widget_subtitle,
                                                                subText
                                                        )
                                                } else {
                                                        // Open App on Widget Click
                                                        val pendingIntent =
                                                                HomeWidgetLaunchIntent.getActivity(
                                                                        context,
                                                                        MainActivity::class.java
                                                                )
                                                        setOnClickPendingIntent(
                                                                R.id.widget_container,
                                                                pendingIntent
                                                        )

                                                        Log.d(
                                                                "EnteMemoryWidgetProvider",
                                                                "Image doesn't exists"
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_img,
                                                                View.GONE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_subtitle,
                                                                View.GONE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_title,
                                                                View.GONE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_overlay,
                                                                View.GONE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_placeholder,
                                                                View.VISIBLE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_placeholder_text,
                                                                View.VISIBLE
                                                        )
                                                        setViewVisibility(
                                                                R.id.widget_placeholder_container,
                                                                View.VISIBLE
                                                        )

                                                        val drawable =
                                                                ContextCompat.getDrawable(
                                                                        context,
                                                                        R.drawable
                                                                                .ic_memories_widget
                                                                )
                                                        val bitmap =
                                                                (drawable as BitmapDrawable).bitmap
                                                        setImageViewBitmap(
                                                                R.id.widget_placeholder,
                                                                bitmap
                                                        )
                                                }
                                        }

                        appWidgetManager.updateAppWidget(widgetId, views)

                        // Schedule automatic slideshow updates
                        scheduleSlideshowUpdate(context, widgetId)
                }
        }

        override fun onDeleted(context: Context, appWidgetIds: IntArray) {
                super.onDeleted(context, appWidgetIds)
                appWidgetIds.forEach { widgetId ->
                        cancelSlideshowUpdate(context, widgetId)
                }
        }

        override fun onDisabled(context: Context) {
                super.onDisabled(context)
                // Cancel all slideshow updates when all widgets are removed
                val appWidgetManager = AppWidgetManager.getInstance(context)
                val appWidgetIds = appWidgetManager.getAppWidgetIds(
                        android.content.ComponentName(context, EnteMemoryWidgetProvider::class.java)
                )
                appWidgetIds.forEach { widgetId ->
                        cancelSlideshowUpdate(context, widgetId)
                }
        }

        private fun scheduleSlideshowUpdate(context: Context, widgetId: Int) {
                val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val intent = Intent(context, EnteMemoryWidgetProvider::class.java).apply {
                        action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                        putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf(widgetId))
                }

                val pendingIntent = PendingIntent.getBroadcast(
                        context,
                        widgetId + 10000, // Offset to avoid conflicts with other widget types
                        intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

                // Schedule repeating alarm for slideshow
                alarmManager.setRepeating(
                        AlarmManager.ELAPSED_REALTIME,
                        SystemClock.elapsedRealtime() + SLIDESHOW_UPDATE_INTERVAL,
                        SLIDESHOW_UPDATE_INTERVAL,
                        pendingIntent
                )

                Log.d("EnteMemoryWidgetProvider", "Scheduled slideshow update for widget $widgetId")
        }

        private fun cancelSlideshowUpdate(context: Context, widgetId: Int) {
                val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val intent = Intent(context, EnteMemoryWidgetProvider::class.java).apply {
                        action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                        putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf(widgetId))
                }

                val pendingIntent = PendingIntent.getBroadcast(
                        context,
                        widgetId + 10000,
                        intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

                alarmManager.cancel(pendingIntent)
                Log.d("EnteMemoryWidgetProvider", "Cancelled slideshow update for widget $widgetId")
        }
}
