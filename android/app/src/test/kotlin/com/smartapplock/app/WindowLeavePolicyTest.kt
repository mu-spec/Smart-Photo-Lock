package com.smartapplock.app

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Phase 5 / F4 P1 pure policy regression tests: a report proves a genuine
 * leave only through the resolved Home package, a UsageEvents activity
 * resume, or an Accessibility window class that PackageManager positively
 * resolves to an Activity of the reporting package. Everything else is
 * UNCONFIRMED and keeps the wake identity and the ready ticket.
 *
 * U1-C: a UsageEvents resume proves a leave only when it is corroborated
 * (Accessibility disabled, or the latest non-transient Accessibility report
 * named the same package). `corroborated = true` below is the pre-U1-C
 * meaning, so the F4 expectations are unchanged.
 *
 * JVM only. These exercise [WindowLeavePolicy] and its composition with the
 * existing H-1/F2/F3 pure policies; they do not run `WatcherService`,
 * PackageManager or Accessibility, and are not device evidence.
 */
class WindowLeavePolicyTest {
    private val locked = "com.intsig.camscanner"
    private val home = "com.oppo.launcher"
    private val ime = "com.google.android.inputmethod.latin"
    private val notes = "com.example.notes"
    private val notesActivity = "com.example.notes.EditorActivity"
    private val gesture = "com.coloros.gesture"
    private val gestureOverlay = "com.coloros.gesture.svg.RootView"
    private val discover = "com.google.android.googlequicksearchbox"

    private var lookups = 0

    /** Models PackageManager for [notes] only: one declared Activity. */
    private val pm: (String, String) -> ResolvedActivity? = { pkg, cls ->
        lookups++
        if (pkg == notes && cls == notesActivity) ResolvedActivity(pkg, cls) else null
    }

    private val throwing: (String, String) -> ResolvedActivity? = { _, _ ->
        lookups++
        throw IllegalStateException("NameNotFound / SecurityException / DeadObject")
    }

    private fun classify(
        pkg: String,
        cls: String?,
        usage: Boolean = false,
        homePackage: String? = home,
        lookup: (String, String) -> ResolvedActivity? = pm,
        corroborated: Boolean = true,
    ) = WindowLeavePolicy.classify(
        packageName = pkg,
        fromUsageEvents = usage,
        usageCorroborated = corroborated,
        homePackage = homePackage,
        windowClass = cls,
        resolveActivity = lookup,
    )

    @Before
    fun resetAccess() {
        ProtectionAccessState.revokeAll()
        ProtectionAccessState.setGracePeriod(0L)
    }

    @After
    fun restoreAccess() {
        ProtectionAccessState.revokeAll()
        ProtectionAccessState.setGracePeriod(0L)
    }

    // -- Classification ---------------------------------------------------------

    @Test
    fun anActivityOfTheReportingPackageIsAConfirmedLeave() {
        assertEquals(ForegroundWindowKind.ACTIVITY, classify(notes, notesActivity))
        assertTrue(WindowLeavePolicy.confirmsLeave(ForegroundWindowKind.ACTIVITY))
    }

    @Test
    fun nullAndBlankWindowClassesAreUnconfirmedWithoutALookup() {
        for (cls in listOf(null, "", "   ")) {
            assertEquals(ForegroundWindowKind.UNCONFIRMED, classify(notes, cls))
        }
        assertEquals(0, lookups)
    }

    @Test
    fun failedOrThrowingLookupsAreUnconfirmed() {
        // Non-activity overlay class: PackageManager finds no such Activity.
        assertEquals(ForegroundWindowKind.UNCONFIRMED, classify(gesture, gestureOverlay))
        assertEquals(
            ForegroundWindowKind.UNCONFIRMED,
            classify(notes, "android.app.Dialog"),
        )
        // NameNotFound (API 30+ package visibility), SecurityException, binder.
        assertEquals(
            ForegroundWindowKind.UNCONFIRMED,
            classify(notes, notesActivity, lookup = throwing),
        )
        assertTrue(lookups >= 3)
    }

    @Test
    fun aLookupThatResolvesToAnotherPackageOrClassIsUnconfirmed() {
        val otherPackage: (String, String) -> ResolvedActivity? =
            { _, cls -> ResolvedActivity("com.attacker.app", cls) }
        val otherClass: (String, String) -> ResolvedActivity? =
            { pkg, _ -> ResolvedActivity(pkg, "com.example.notes.OtherActivity") }
        assertEquals(
            ForegroundWindowKind.UNCONFIRMED,
            classify(notes, notesActivity, lookup = otherPackage),
        )
        assertEquals(
            ForegroundWindowKind.UNCONFIRMED,
            classify(notes, notesActivity, lookup = otherClass),
        )
    }

    @Test
    fun theResolvedHomePackageIsAlwaysAConfirmedLeaveWhateverTheWindow() {
        assertEquals(ForegroundWindowKind.HOME, classify(home, null))
        assertEquals(ForegroundWindowKind.HOME, classify(home, "android.widget.FrameLayout"))
        assertEquals(ForegroundWindowKind.HOME, classify(home, "x", lookup = throwing))
        assertEquals(ForegroundWindowKind.HOME, classify(home, null, usage = true))
        assertTrue(WindowLeavePolicy.confirmsLeave(ForegroundWindowKind.HOME))
    }

    @Test
    fun aLauncherNameIsNotHomeUnlessTheHomeResolverReturnedIt() {
        // No package-name assumption: only the safe-exit Home resolver counts.
        assertEquals(
            ForegroundWindowKind.UNCONFIRMED,
            classify(home, null, homePackage = "com.example.otherhome"),
        )
        assertEquals(ForegroundWindowKind.UNCONFIRMED, classify(home, null, homePackage = null))
        assertEquals(ForegroundWindowKind.UNCONFIRMED, classify(home, null, homePackage = ""))
    }

    @Test
    fun launcherHostedOverlayIsUnconfirmedUntilTheHomePackageReports() {
        // Oppo CPH2083 logcat: googlequicksearchbox is reported during the
        // Home transition, and it is also a full app. Only its window kind
        // or the Home package decides; never its name.
        val overlay = classify(discover, "com.google.android.apps.gsa.OverlayRootView")
        assertEquals(ForegroundWindowKind.UNCONFIRMED, overlay)
        assertTrue(WindowLeavePolicy.provesNothing(transient = false, kind = overlay))
        val launcher = classify(home, null)
        assertFalse(WindowLeavePolicy.provesNothing(transient = false, kind = launcher))
    }

    @Test
    fun usageEventsResumesAreActivityLevelLeaveEvidence() {
        assertEquals(ForegroundWindowKind.USAGE_ACTIVITY, classify(notes, null, usage = true))
        assertEquals(
            ForegroundWindowKind.USAGE_ACTIVITY,
            classify(gesture, null, usage = true, lookup = throwing),
        )
        assertEquals(0, lookups)
        assertTrue(WindowLeavePolicy.confirmsLeave(ForegroundWindowKind.USAGE_ACTIVITY))
    }

    @Test
    fun aBlankPackageNeverProvesALeave() {
        assertEquals(ForegroundWindowKind.UNCONFIRMED, classify("", notesActivity))
        assertEquals(ForegroundWindowKind.UNCONFIRMED, classify(" ", null, usage = true))
        assertEquals(ForegroundWindowKind.UNCONFIRMED, classify("", null, homePackage = ""))
    }

    @Test
    fun provesNothingIsTransientOrUnconfirmed() {
        for (kind in ForegroundWindowKind.values()) {
            assertTrue(WindowLeavePolicy.provesNothing(transient = true, kind = kind))
        }
        assertTrue(
            WindowLeavePolicy.provesNothing(false, ForegroundWindowKind.UNCONFIRMED),
        )
        for (kind in listOf(
            ForegroundWindowKind.HOME,
            ForegroundWindowKind.USAGE_ACTIVITY,
            ForegroundWindowKind.ACTIVITY,
        )) {
            assertFalse(WindowLeavePolicy.provesNothing(transient = false, kind = kind))
        }
        assertFalse(WindowLeavePolicy.confirmsLeave(ForegroundWindowKind.UNCONFIRMED))
    }

    // -- Composition with H-1 F1/F2 ---------------------------------------------

    private fun provesNothing(
        pkg: String,
        cls: String?,
        usage: Boolean = false,
        corroborated: Boolean = true,
    ) = WindowLeavePolicy.provesNothing(
        transient = ChallengeAbandonPolicy.isTransientWindow(pkg, ime),
        kind = classify(pkg, cls, usage, corroborated = corroborated),
    )

    @Test
    fun anUnconfirmedOverlayKeepsTheWakeIdentityAndTheReadyTicket() {
        for ((pkg, cls) in listOf(
            gesture to gestureOverlay,
            "com.coloros.screenshot" to null,
            "com.facebook.orca" to "com.facebook.messenger.chatheads.ChatHeadView",
            discover to "android.widget.FrameLayout",
        )) {
            val nothing = provesNothing(pkg, cls)
            assertTrue(pkg, nothing)
            assertFalse(pkg, ChallengeAbandonPolicy.mayForgetWakeIdentity(false, nothing))
            assertEquals(
                pkg,
                ReadyTicketAction.KEEP,
                ChallengeAbandonPolicy.readyTicketAction(false, nothing, true, true),
            )
            assertEquals(
                pkg,
                ReadyTicketAction.KEEP,
                ChallengeAbandonPolicy.readyTicketAction(false, nothing, false, true),
            )
            // SCREEN_OFF: the overlay is observed, the identity is remembered.
            assertEquals(
                pkg,
                locked,
                WakeReauthTargetPolicy.resolve(pkg, locked) { it == locked },
            )
        }
    }

    @Test
    fun aConfirmedActivityLeaveKeepsTheExistingDeferAndAbandonBehaviour() {
        val nothing = provesNothing(notes, notesActivity)
        assertFalse(nothing)
        assertTrue(ChallengeAbandonPolicy.mayForgetWakeIdentity(false, nothing))
        assertEquals(
            ReadyTicketAction.DEFER,
            ChallengeAbandonPolicy.readyTicketAction(false, nothing, true, true),
        )
        assertEquals(
            ReadyTicketAction.ABANDON,
            ChallengeAbandonPolicy.readyTicketAction(false, nothing, false, true),
        )
        // The identity was forgotten, so SCREEN_OFF has no protected target.
        assertNull(WakeReauthTargetPolicy.resolve(notes, null) { it == locked })
    }

    @Test
    fun homeAndUsageLeavesForgetAndAbandonEvenWithUnknownWindowClasses() {
        for (nothing in listOf(
            provesNothing(home, null),
            provesNothing(home, "com.oppo.launcher.recents.RecentsView"),
            provesNothing(notes, null, usage = true),
        )) {
            assertFalse(nothing)
            assertTrue(ChallengeAbandonPolicy.mayForgetWakeIdentity(false, nothing))
            assertEquals(
                ReadyTicketAction.DEFER,
                ChallengeAbandonPolicy.readyTicketAction(false, nothing, true, true),
            )
            assertEquals(
                ReadyTicketAction.ABANDON,
                ChallengeAbandonPolicy.readyTicketAction(false, nothing, false, true),
            )
        }
    }

    @Test
    fun transientAndScreenOffBehaviourIsUnchanged() {
        // Transient wins even over Home/Usage (H-1 unchanged).
        assertTrue(provesNothing("com.android.systemui", null, usage = true))
        assertTrue(provesNothing(ime, null))
        // Screen non-interactive keeps the ticket whatever the window kind.
        for (nothing in listOf(true, false)) {
            assertEquals(
                ReadyTicketAction.KEEP,
                ChallengeAbandonPolicy.readyTicketAction(false, nothing, false, false),
            )
        }
        // Protected targets are untouched by the classification.
        assertEquals(
            ReadyTicketAction.KEEP,
            ChallengeAbandonPolicy.readyTicketAction(true, false, false, true),
        )
        assertFalse(ChallengeAbandonPolicy.mayForgetWakeIdentity(true, false))
    }

    // -- Composition with F3 restart recovery -----------------------------------

    @Test
    fun aRetainedIdentityAfterAnOverlaySurvivesAnF3RestartWithUsageOff() {
        val now = 1_800_000_000_000L
        val retained = if (ChallengeAbandonPolicy.mayForgetWakeIdentity(
                false,
                provesNothing(gesture, gestureOverlay),
            )
        ) {
            null
        } else {
            locked
        }
        val result = RestartRecoveryPolicy.decide(
            RestartRecoveryInput(
                protectionEnabled = true,
                pendingExists = false,
                uiActivityResumed = false,
                rememberedPackage = retained,
                rememberedSameBoot = true,
                rememberedStampWallMs = now - 10_000L,
                wallClockConsistent = true,
                evidence = ForegroundEvidence.Unknown,
            ),
        ) { it == locked }
        assertEquals(RestartRecoveryDecision.CHALLENGE_REMEMBERED_FOREGROUND_UNKNOWN, result.decision)
    }

    @Test
    fun theF3SelectorStillIgnoresWindowKindAndUsesOnlyH1Transience() {
        // Unchanged: only activity resumes reach UsageEvents, so an OEM
        // activity resume after the protected one is still newer evidence.
        val now = 1_800_000_000_000L
        val selector = RestartForegroundEvidenceSelector(
            "com.smartapplock.app",
            ime,
            now,
            now - 3_600_000L,
        )
        selector.offer(locked, now - 10_000L, true)
        selector.offer(gesture, now - 5_000L, true)
        selector.offer("com.android.systemui", now - 1_000L, true)
        assertEquals(ForegroundEvidence.App(gesture, now - 5_000L), selector.result())
    }

    // -- Authorization is independent of the window kind (H-2 / OD3) ------------

    @Test
    fun graceZeroStillRevokesOnAnUnconfirmedOverlayReport() {
        ProtectionAccessState.setGracePeriod(0L)
        ProtectionAccessState.authorize(locked, 300_000L, 1_000L)
        assertEquals(
            ProtectionAccessState.Decision.ALLOW,
            ProtectionAccessState.observeForeground(gesture, false, 2_000L),
        )
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            ProtectionAccessState.observeForeground(locked, true, 2_100L),
        )
    }

    @Test
    fun gracePositiveStillStartsTheAwayWindowOnAnUnconfirmedOverlayReport() {
        ProtectionAccessState.setGracePeriod(10_000L)
        ProtectionAccessState.authorize(locked, 300_000L, 1_000L)
        ProtectionAccessState.observeForeground(gesture, false, 2_000L)
        assertEquals(
            ProtectionAccessState.Decision.ALLOW,
            ProtectionAccessState.observeForeground(locked, true, 5_000L),
        )
        ProtectionAccessState.observeForeground(gesture, false, 6_000L)
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            ProtectionAccessState.observeForeground(locked, true, 16_000L),
        )
    }

    // -- U1-C: UsageEvents leave evidence needs corroboration -------------------

    @Test
    fun u1cAnUncorroboratedUsageResumeIsUnconfirmedWithoutALookup() {
        for (pkg in listOf(notes, gesture, "com.cloudflare.onedotonedotonedotone")) {
            assertEquals(
                pkg,
                ForegroundWindowKind.UNCONFIRMED,
                classify(pkg, null, usage = true, corroborated = false),
            )
            assertTrue(pkg, provesNothing(pkg, null, usage = true, corroborated = false))
        }
        assertEquals(0, lookups)
    }

    @Test
    fun u1cACorroboratedUsageResumeIsStillActivityLevelLeaveEvidence() {
        assertEquals(
            ForegroundWindowKind.USAGE_ACTIVITY,
            classify(notes, null, usage = true, corroborated = true),
        )
        assertFalse(provesNothing(notes, null, usage = true, corroborated = true))
    }

    @Test
    fun u1cUsageHomeNeedsCorroborationButAccessibilityHomeIsAlwaysHome() {
        assertEquals(
            ForegroundWindowKind.UNCONFIRMED,
            classify(home, null, usage = true, corroborated = false),
        )
        assertEquals(
            ForegroundWindowKind.HOME,
            classify(home, null, usage = true, corroborated = true),
        )
        // The flag describes UsageEvents only: Accessibility Home is unchanged.
        assertEquals(ForegroundWindowKind.HOME, classify(home, null, corroborated = false))
        assertEquals(
            ForegroundWindowKind.HOME,
            classify(home, "x", lookup = throwing, corroborated = false),
        )
    }

    @Test
    fun u1cCorroborationNeverChangesAccessibilityClassification() {
        for (corroborated in listOf(true, false)) {
            assertEquals(
                ForegroundWindowKind.ACTIVITY,
                classify(notes, notesActivity, corroborated = corroborated),
            )
            assertEquals(
                ForegroundWindowKind.UNCONFIRMED,
                classify(gesture, gestureOverlay, corroborated = corroborated),
            )
            assertEquals(
                ForegroundWindowKind.UNCONFIRMED,
                classify(notes, null, corroborated = corroborated),
            )
        }
    }

    @Test
    fun u1cABlankUsagePackageIsUnconfirmedWhateverTheCorroboration() {
        for (corroborated in listOf(true, false)) {
            assertEquals(
                ForegroundWindowKind.UNCONFIRMED,
                classify(" ", null, usage = true, corroborated = corroborated),
            )
        }
    }

    @Test
    fun u1cAnUncorroboratedUsageLeaveKeepsTheWakeIdentityAndTheReadyTicket() {
        for (pkg in listOf(notes, home)) {
            val nothing = provesNothing(pkg, null, usage = true, corroborated = false)
            assertTrue(pkg, nothing)
            assertFalse(pkg, ChallengeAbandonPolicy.mayForgetWakeIdentity(false, nothing))
            assertEquals(
                pkg,
                ReadyTicketAction.KEEP,
                ChallengeAbandonPolicy.readyTicketAction(false, nothing, true, true),
            )
            assertEquals(
                pkg,
                ReadyTicketAction.KEEP,
                ChallengeAbandonPolicy.readyTicketAction(false, nothing, false, true),
            )
        }
    }

    @Test
    fun u1cAnUncorroboratedUsageReportStillRevokesAuthorization() {
        // observeForeground stays unconditional: the window kind is irrelevant.
        ProtectionAccessState.setGracePeriod(0L)
        ProtectionAccessState.authorize(locked, 300_000L, 1_000L)
        ProtectionAccessState.observeForeground(notes, false, 7_000L)
        assertEquals(
            ProtectionAccessState.Decision.CHALLENGE,
            ProtectionAccessState.observeForeground(locked, true, 7_100L),
        )
    }
}
