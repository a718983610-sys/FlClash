package com.follow.clash

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import androidx.core.content.pm.ShortcutManagerCompat
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.common.QuickAction
import com.follow.clash.common.action
import com.follow.clash.common.intent
import com.follow.clash.common.shortcutId
import kotlinx.coroutines.launch

class QuickActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
        finish()
    }

    // A caller that repeats an action before this instance is gone reaches it here, not onCreate.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent) {
        val action = QuickAction.entries.firstOrNull { it.action == intent.action } ?: return
        ShortcutManagerCompat.reportShortcutUsed(this, action.shortcutId)
        val blocked = GlobalState.application.qfGuestBlockedCore
        val wouldStart = when (action) {
            QuickAction.START -> true
            QuickAction.TOGGLE -> !ServiceState.isRunRequested
            QuickAction.STOP -> false
        }
        if (blocked && wouldStart) {
            openMainApp()
            return
        }
        GlobalState.launch {
            when (action) {
                QuickAction.START -> ServiceState.handleStartAction()
                QuickAction.STOP -> ServiceState.handleStopAction()
                QuickAction.TOGGLE -> ServiceState.handleToggleAction()
            }
        }
    }

    private fun openMainApp() {
        runCatching {
            startActivity(
                Components.mainActivity.intent.apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                },
            )
        }
    }
}
