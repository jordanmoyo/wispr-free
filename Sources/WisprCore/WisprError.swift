import Foundation

public enum WisprError: Error, Equatable {
    case modelNotLoaded
    case recordingFailed
    case hotkeyTapFailed
}
