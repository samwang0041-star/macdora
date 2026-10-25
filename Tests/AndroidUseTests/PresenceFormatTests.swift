import XCTest
@testable import AndroidUse

final class PresenceFormatTests: XCTestCase {
    func testAndroid15PermissionWindowOnTargetDisplayRemainsInteractive() {
        let activity = """
        Display #4 (activities from top to bottom):
          * Hist #1: ActivityRecord{test com.android.permissioncontroller/.GrantPermissionsActivity}
            state=RESUMED
            mVisibleRequested=true mVisible=true
          * Hist #0: ActivityRecord{test \(DemoApp.package)/com.yanzhenjie.permission.PermissionActivity}
            state=PAUSED
            mVisibleRequested=true mVisible=true
        Display #0
          topResumedActivity=ActivityRecord{test com.android.launcher3/.Launcher}
        """
        let window = """
        Display: mDisplayId=0
          mCurrentFocus=Window{test com.android.launcher3/.Launcher}
        Display: mDisplayId=4
          mCurrentFocus=Window{test com.android.permissioncontroller/.GrantPermissionsActivity}
          mFocusedApp=ActivityRecord{test com.android.permissioncontroller/.GrantPermissionsActivity}
        """
        XCTAssertEqual(RuntimePresenceParser.resolve(Data(activity.utf8), window: Data(window.utf8), package: DemoApp.package), .systemInteraction)
    }

    func testVisibleActivityFlagsCanBeOnSeparateLinesAndDefaultDisplayIsExcluded() {
        let activity = """
        Display #3
          * Hist #0: ActivityRecord{test \(DemoApp.package)/.LoginActivity}
            mResumedActivity: ActivityRecord{test \(DemoApp.package)/.LoginActivity}
            state=RESUMED
            mVisibleRequested=true mVisible=true
        """
        XCTAssertEqual(RuntimePresenceParser.resolve(Data(activity.utf8), window: nil, package: DemoApp.package), .visible)
        XCTAssertEqual(RuntimePresenceParser.resolve(Data(activity.replacingOccurrences(of: "Display #3", with: "Display #0").utf8), window: nil, package: DemoApp.package), .notRunning)
        let hidden = activity.replacingOccurrences(of: "Display #3", with: "Display #0")
            .replacingOccurrences(of: "state=RESUMED", with: "state=STOPPED")
            .replacingOccurrences(of: "mVisibleRequested=true", with: "mVisibleRequested=false")
            .replacingOccurrences(of: "mVisible=true", with: "mVisible=false")
        let unrelated = """
        Display: mDisplayId=3
          mCurrentFocus=Window{test com.android.permissioncontroller/.GrantPermissionsActivity}
        Display: mDisplayId=0
          mCurrentFocus=null
        """
        XCTAssertEqual(RuntimePresenceParser.resolve(Data(hidden.utf8), window: Data(unrelated.utf8), package: DemoApp.package), .notRunning)
    }

    func testDocumentsPickerOnTargetDisplayKeepsDemoSessionAliveAndDefaultDisplayCannotBecomeReady() {
        let activity = """
        Display #5
          * Hist #0: ActivityRecord{test \(DemoApp.package)/.MainActivity}
            mResumedActivity: ActivityRecord{test \(DemoApp.package)/.MainActivity}
            state=STOPPED
            mVisibleRequested=false mVisible=false
        """
        let window = """
        Display: mDisplayId=5
          mCurrentFocus=Window{test com.android.documentsui/.picker.PickActivity}
        """
        XCTAssertEqual(RuntimePresenceParser.resolve(Data(activity.utf8), window: Data(window.utf8), package: DemoApp.package), .systemInteraction)
        let defaultActivity = activity.replacingOccurrences(of: "Display #5", with: "Display #0")
        let defaultWindow = window.replacingOccurrences(of: "mDisplayId=5", with: "mDisplayId=0").replacingOccurrences(of: "com.android.documentsui", with: "com.android.permissioncontroller")
        XCTAssertEqual(RuntimePresenceParser.resolve(Data(defaultActivity.utf8), window: Data(defaultWindow.utf8), package: DemoApp.package), .notRunning)
    }

    func testSettingsSearchActivityOnVirtualDisplayKeepsSettingsSessionAlive() {
        let activity = """
        Display #0 (activities from top to bottom):
          * Task{28ce8b5 #125 type=standard A=1000:com.android.settings.root U=0 visible=false visibleRequested=false mode=fullscreen translucent=true sz=1}
            * Hist  #0: ActivityRecord{142253292 u0 com.android.settings/.Settings t125}
              state=STOPPED finishing=false
              mVisibleRequested=false mVisible=false
        Display #2 (activities from top to bottom):
          * Task{17aba34 #126 type=standard A=1000:com.android.settings.root U=0 visible=true visibleRequested=true mode=fullscreen translucent=false sz=2}
            topResumedActivity=ActivityRecord{246932755 u0 com.android.settings.intelligence/.search.SearchActivity t126}
            * Hist  #1: ActivityRecord{246932755 u0 com.android.settings.intelligence/.search.SearchActivity t126}
              packageName=com.android.settings.intelligence processName=com.android.settings.intelligence
              launchedFromUid=1000 launchedFromPackage=com.android.settings launchedFromFeature=null userId=0
              rootOfTask=false task=Task{17aba34 #126 type=standard A=1000:com.android.settings.root}
              state=RESUMED finishing=false
              mVisibleRequested=true mVisible=true mClientVisible=true reportedDrawn=true reportedVisible=true
            * Hist  #0: ActivityRecord{40163591 u0 com.android.settings/.Settings t126}
              packageName=com.android.settings processName=com.android.settings
              rootOfTask=true task=Task{17aba34 #126 type=standard A=1000:com.android.settings.root}
              state=STOPPED finishing=false
              mVisibleRequested=false mVisible=false mClientVisible=false reportedDrawn=false reportedVisible=false
        """
        let window = """
        Display: mDisplayId=0 (organized)
          mCurrentFocus=null
          mFocusedApp=ActivityRecord{37189679 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t124}
        Display: mDisplayId=2 (organized)
          mCurrentFocus=Window{e99e9f8 u0 com.android.settings.intelligence/com.android.settings.intelligence.search.SearchActivity}
          mFocusedApp=ActivityRecord{246932755 u0 com.android.settings.intelligence/.search.SearchActivity t126}
        """
        XCTAssertTrue(RuntimePresenceParser.hasTargetVisible(Data(activity.utf8), package: "com.android.settings"))
        XCTAssertEqual(RuntimePresenceParser.targetDisplay(in: Data(activity.utf8), package: "com.android.settings"), 2)
        XCTAssertTrue(RuntimePresenceParser.hasSystemInteraction(Data(window.utf8), display: 2))
        let resolved = RuntimePresenceParser.resolve(Data(activity.utf8), window: Data(window.utf8), package: "com.android.settings")
        XCTAssertNotEqual(resolved, .notRunning)
        XCTAssertNotEqual(resolved, .unavailable)

        let searchResultChild = """
        Display #2 (activities from top to bottom):
          * Task{17aba34 #126 type=standard A=1000:com.android.settings.root U=0 visible=true visibleRequested=true mode=fullscreen translucent=false sz=3}
            topResumedActivity=ActivityRecord{99887766 u0 com.android.cellbroadcastreceiver.module/com.android.cellbroadcastreceiver.CellBroadcastSettings t126}
            * Hist  #2: ActivityRecord{99887766 u0 com.android.cellbroadcastreceiver.module/com.android.cellbroadcastreceiver.CellBroadcastSettings t126}
              launchedFromUid=10099 launchedFromPackage=com.android.settings.intelligence launchedFromFeature=null userId=0
              rootOfTask=false task=Task{17aba34 #126 type=standard A=1000:com.android.settings.root}
              state=RESUMED finishing=false
              mVisibleRequested=true mVisible=true
        """
        XCTAssertTrue(RuntimePresenceParser.hasTargetVisible(Data(searchResultChild.utf8), package: "com.android.settings"))
    }
}
