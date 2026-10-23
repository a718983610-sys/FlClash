package com.follow.clash

import android.annotation.SuppressLint
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.common.QuickAction
import com.follow.clash.common.intent
import com.follow.clash.common.quickIntent
import com.follow.clash.common.toPendingIntent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class TileService : android.service.quicksettings.TileService() {
    private var scope: CoroutineScope? = null
    private var currentRunState: RunState = RunState.STOPPED

    override fun onStartListening() {
        super.onStartListening()
        scope?.cancel()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).also { scope ->
            scope.launch {
                ServiceState.runState.collect(::updateTile)
            }
        }
    }

    // Always route through QuickActionActivity: startActivityAndCollapse is
    // what closes the shade, so toggling the service in place would leave
    // the panel open after a tap.
    override fun onClick() {
        super.onClick()
        if (GlobalState.application.qfGuestBlockedCore &&
            currentRunState == RunState.STOPPED
        ) {
            openMainApp()
            return
        }
        openQuickAction()
    }

    override fun onStopListening() {
        scope?.cancel()
        scope = null
        super.onStopListening()
    }

    private fun updateTile(runState: RunState) {
        currentRunState = runState
        qsTile?.apply {
            state = when (runState) {
                RunState.STARTED -> Tile.STATE_ACTIVE
                RunState.STARTING, RunState.STOPPING -> Tile.STATE_UNAVAILABLE
                RunState.STOPPED -> Tile.STATE_INACTIVE
            }
            updateTile()
        }
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openQuickAction() {
        val intent = QuickAction.TOGGLE.quickIntent
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(intent.toPendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openMainApp() {
        val intent = Components.mainActivity.intent.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(intent.toPendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
