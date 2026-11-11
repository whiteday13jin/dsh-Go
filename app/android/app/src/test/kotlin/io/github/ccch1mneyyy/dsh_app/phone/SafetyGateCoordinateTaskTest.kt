package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.*
import org.junit.Test

/**
 * 1.0.14's release note promises one permission per task and app for
 * snapshot-coordinate taps. An app approved for this task covers plain
 * coordinate taps; long press and swipe keep asking every time.
 */
class SafetyGateCoordinateTaskTest {
    private class Fixture(
        val mode: ConfirmMode = ConfirmMode.ASK,
        val everyWrite: List<String> = emptyList(),
        val deny: List<String> = emptyList(),
    ) {
        val tasks = PhoneTasks().apply { begin() }
        val owner = tasks.activeOwner()!!
        val asks = mutableListOf<ConfirmRequest>()
        var answer: (ConfirmRequest) -> Decision = { Decision.ALLOW_APP_FOR_TASK }
        private val ui = object : UserGate {
            override fun confirm(request: ConfirmRequest): Decision {
                asks += request
                return answer(request)
            }
            override fun handoff(reason: String, timeoutMs: Long): HandoffResult = error("unexpected handoff")
            override fun status(text: String?) = Unit
        }
        val safety = SafetyGate(
            { PhonePolicies(denyPackages = deny, confirmEveryWritePackages = everyWrite, confirmMode = mode) },
            tasks,
            { ui },
        )
        fun tap(
            pkg: String = "com.taobao.idlefish",
            app: String = "闲鱼",
            gesture: PhoneAction.CoordinateGesture = PhoneAction.CoordinateGesture.TAP,
        ): SafetyGate.Result = safety.resolve(
            safety.checkWrite(
                WriteKind.TAP_XY, null, pkg, app, point = 40 to 60,
                coordinate = PhoneAction.TapXY("s1", 40, 60, gesture),
                screen = PhoneScreen.MAIN, visual = null,
            ),
            SerialWorker.Scope(), owner,
        )
    }

    @Test fun firstCoordinateTapOffersAppForTaskAndCoversTheRest() {
        val f = Fixture()
        assertEquals("confirmed-app", (f.tap() as SafetyGate.Result.Go).decision)
        val ask = f.asks.single()
        assertTrue(ask.firstInApp)
        assertFalse(ask.offerTaskWaiver)
        assertNull(ask.visualScope)
        assertTrue(f.tasks.isApproved("com.taobao.idlefish"))
        assertEquals("allowed", (f.tap() as SafetyGate.Result.Go).decision)
        assertEquals(1, f.asks.size)
    }

    @Test fun approvalStaysPerAppAndPerTask() {
        val f = Fixture()
        f.tap()
        assertEquals("confirmed-app", (f.tap(pkg = "com.tmall.wireless", app = "天猫") as SafetyGate.Result.Go).decision)
        assertEquals(2, f.asks.size)
        assertTrue(f.asks[1].firstInApp)
    }

    @Test fun longPressAndSwipeStillAskEveryTime() {
        val f = Fixture()
        f.tap()
        f.tap(gesture = PhoneAction.CoordinateGesture.LONG)
        f.tap(gesture = PhoneAction.CoordinateGesture.LONG)
        f.tap(gesture = PhoneAction.CoordinateGesture.SWIPE)
        assertEquals(4, f.asks.size)
        // They never offer an app-scoped grant the grant would not honour.
        assertTrue(f.asks.drop(1).all { !it.firstInApp })
    }

    @Test fun everyWriteAppKeepsAskingEveryTime() {
        val f = Fixture(everyWrite = listOf("com.taobao.idlefish"))
        f.tap()
        f.tap()
        assertEquals(2, f.asks.size)
        // A 每一步都确认 app never offers the task-scoped app approval, so every
        // coordinate gesture still asks.
        assertTrue(f.asks.all { !it.firstInApp })
        assertFalse(f.tasks.isApproved("com.taobao.idlefish"))
    }

    @Test fun allowOnceKeepsTheOldEveryTimeBehaviour() {
        val f = Fixture()
        f.answer = { Decision.ALLOW_ONCE }
        f.tap()
        f.tap()
        assertEquals(2, f.asks.size)
        assertFalse(f.tasks.isApproved("com.taobao.idlefish"))
    }

    @Test fun alwaysModeStillAsksOnceForAnUnknownCoordinateTarget() {
        val f = Fixture(mode = ConfirmMode.ALWAYS)
        assertEquals("confirmed-app", (f.tap() as SafetyGate.Result.Go).decision)
        assertEquals("allowed", (f.tap() as SafetyGate.Result.Go).decision)
        assertEquals(1, f.asks.size)
    }

    @Test fun backgroundCoordinatesKeepAskingEvenAfterTheAppIsApproved() {
        val f = Fixture()
        f.tap()
        val background = f.safety.checkWrite(WriteKind.TAP_XY, null, "com.taobao.idlefish", "闲鱼",
            point = 40 to 60, coordinate = PhoneAction.TapXY("b1", 40, 60),
            screen = PhoneScreen.BACKGROUND, visual = null)
        assertTrue(background is SafetyGate.Verdict.Confirm)
        assertFalse((background as SafetyGate.Verdict.Confirm).request.firstInApp)
        assertFalse(background.request.offerTaskWaiver)
    }

    @Test fun hardRulesStillRefuseBeforeAnyGrant() {
        val denied = Fixture(deny = listOf("com.taobao.idlefish"))
        assertEquals("refused:deny-list", (denied.tap() as SafetyGate.Result.No).decision)
        assertTrue(denied.asks.isEmpty())
        val system = Fixture()
        assertEquals("refused:system-page", (system.tap(pkg = "com.android.settings", app = "设置") as SafetyGate.Result.No).decision)
        assertTrue(system.asks.isEmpty())
    }

    @Test fun aNewTaskDoesNotInheritTheApproval() {
        val f = Fixture()
        f.tap()
        assertTrue(f.tasks.finish())
        f.tasks.begin()
        val next = f.tasks.activeOwner()!!
        val result = f.safety.resolve(
            f.safety.checkWrite(WriteKind.TAP_XY, null, "com.taobao.idlefish", "闲鱼", point = 40 to 60,
                coordinate = PhoneAction.TapXY("s1", 40, 60), screen = PhoneScreen.MAIN, visual = null),
            SerialWorker.Scope(), next,
        )
        assertEquals("confirmed-app", (result as SafetyGate.Result.Go).decision)
        assertEquals(2, f.asks.size)
    }
}
