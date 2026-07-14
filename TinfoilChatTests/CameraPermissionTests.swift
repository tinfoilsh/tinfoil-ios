import AVFoundation
import Testing
@testable import TinfoilChat

@Suite("Camera Permission Tests")
struct CameraPermissionTests {
    @Test("Presents the camera when access is authorized")
    func presentsCameraWhenAuthorized() {
        #expect(cameraPermissionAction(for: .authorized) == .presentCamera)
    }

    @Test("Requests access when permission is undetermined")
    func requestsUndeterminedAccess() {
        #expect(cameraPermissionAction(for: .notDetermined) == .requestAccess)
    }

    @Test("Shows Settings guidance when camera access is unavailable")
    func showsSettingsGuidance() {
        #expect(cameraPermissionAction(for: .denied) == .showSettingsAlert)
        #expect(cameraPermissionAction(for: .restricted) == .showSettingsAlert)
    }
}
